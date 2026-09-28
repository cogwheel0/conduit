import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../shell_bridge.dart';

/// Opens a transport to the daemon.
///
/// Abstracted away from [WebSocketChannel] so tests can drive a [RpcClient]
/// over an in-memory channel: the reconnect, seeding and subscription-replay
/// logic is worth testing without a real socket or a real daemon.
typedef SocketOpener = Future<StreamChannel<String>> Function(
  Uri uri,
  List<String> protocols,
);

/// The production opener.
Future<StreamChannel<String>> _openWebSocket(
  Uri uri,
  List<String> protocols,
) async {
  final socket = WebSocketChannel.connect(uri, protocols: protocols);
  // Surfaces a rejected handshake (bad origin, bad token) as an error here
  // rather than as a silently dead channel.
  await socket.ready;
  return socket.cast<String>();
}

/// Where the renderer stands with respect to the core.
enum CoreConnectionState {
  connecting,

  /// Socket open and `system.handshake` accepted.
  connected,

  /// The socket dropped; a retry is scheduled. The UI shows a banner and
  /// keeps whatever it has on screen rather than blanking.
  reconnecting,

  /// Retries exhausted, or a mismatch no retry can fix (a protocol version
  /// difference means the wrong binary is installed).
  failed,
}

/// Snapshot of the connection, rebuilt on every transition.
class CoreConnection {
  const CoreConnection({
    required this.state,
    this.handshake,
    this.error,
    this.attempt = 0,
  });

  final CoreConnectionState state;

  /// Null until the first successful handshake, then retained across
  /// reconnects so the UI can keep rendering known capabilities.
  final HandshakeResponse? handshake;
  final RpcError? error;

  /// Consecutive failed attempts; drives the backoff and the banner copy.
  final int attempt;

  bool get isUsable => state == CoreConnectionState.connected;

  Capabilities get capabilities => handshake?.capabilities ?? Capabilities.none;
}

/// Owns the WebSocket to `conduitd` and the JSON-RPC peer on top of it.
///
/// Reconnects with exponential backoff and replays its subscription, which is
/// why [EventSubscription] is declarative: recovery is one call, not a diff.
class RpcClient {
  RpcClient({
    required this.bridge,
    required this.clientVersion,
    this.locale = 'en',
    this.maxAttempts = 8,
    this.heartbeatInterval = const Duration(seconds: 5),
    Future<void> Function(Duration delay)? delay,
    SocketOpener? connect,
  }) : _delay = delay ?? ((d) => Future<void>.delayed(d)),
       _connect = connect ?? _openWebSocket;

  final ShellBridge bridge;
  final String clientVersion;
  final String locale;

  /// Attempts before giving up and surfacing a hard failure. Electron
  /// restarts a crashed daemon with its own backoff, so the renderer only has
  /// to outlast that.
  final int maxAttempts;

  /// How often the UI pings the daemon. A wedged event loop shows up as a
  /// timed-out ping rather than as a silently stalled window.
  final Duration heartbeatInterval;
  final Future<void> Function(Duration delay) _delay;
  final SocketOpener _connect;

  final StreamController<CoreConnection> _connectionController =
      StreamController<CoreConnection>.broadcast();
  final StreamController<EventEnvelope> _eventController =
      StreamController<EventEnvelope>.broadcast();

  /// Connection transitions, starting with the current state.
  ///
  /// Seeding matters because [start] runs before the first component
  /// subscribes: the socket is usually up by the time the UI mounts, and a
  /// plain broadcast stream would leave that component waiting on a
  /// transition that already happened.
  ///
  /// The seed is added *after* subscribing to the source rather than before,
  /// so a transition landing in between is queued behind it instead of lost.
  Stream<CoreConnection> get connection {
    late final StreamController<CoreConnection> controller;
    StreamSubscription<CoreConnection>? subscription;
    controller = StreamController<CoreConnection>(
      onListen: () {
        subscription = _connectionController.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.add(_current);
      },
      onCancel: () => subscription?.cancel(),
    );
    return controller.stream;
  }

  /// Every event the daemon pushed that this client subscribed to.
  Stream<EventEnvelope> get events => _eventController.stream;

  CoreConnection _current = const CoreConnection(
    state: CoreConnectionState.connecting,
  );
  CoreConnection get current => _current;

  json_rpc.Peer? _peer;
  Timer? _heartbeat;
  bool _disposed = false;

  /// The interest set, replayed after every reconnect.
  EventSubscription _subscription = const EventSubscription();

  /// Highest sequence number seen. A jump means events were missed while the
  /// socket was down and the UI must refetch rather than patch.
  int _lastSeq = 0;
  int get lastSeq => _lastSeq;

  /// True when the last reconnect revealed a gap in the event sequence.
  bool _missedEvents = false;
  bool get missedEvents => _missedEvents;

  Future<void> start() async {
    for (var attempt = 0; attempt < maxAttempts && !_disposed; attempt++) {
      if (attempt > 0) {
        _emit(
          CoreConnection(
            state: CoreConnectionState.reconnecting,
            handshake: _current.handshake,
            attempt: attempt,
          ),
        );
        await _delay(_backoffFor(attempt));
        if (_disposed) return;
      }

      try {
        await _connectOnce();
        // _connectOnce returns when the socket closes. A clean close after a
        // successful handshake is still a disconnect worth retrying, so fall
        // through to the next attempt.
        if (_disposed) return;
        attempt = -1; // Reset backoff: this connection did work.
        continue;
      } on RpcError catch (error) {
        if (error.code == ConduitErrorCodes.protocolVersionMismatch) {
          // Retrying cannot help: the installed binaries disagree. Stop
          // immediately and let the UI say so.
          _emit(
            CoreConnection(
              state: CoreConnectionState.failed,
              error: error,
              attempt: attempt + 1,
            ),
          );
          return;
        }
        _lastError = error;
      } catch (error) {
        _lastError = RpcError.fromException(error);
      }
    }

    if (!_disposed) {
      _emit(
        CoreConnection(
          state: CoreConnectionState.failed,
          handshake: _current.handshake,
          error:
              _lastError ??
              const RpcError(code: ConduitErrorCodes.daemonUnavailable),
          attempt: maxAttempts,
        ),
      );
    }
  }

  RpcError? _lastError;

  Future<void> _connectOnce() async {
    _emit(
      CoreConnection(
        state: _current.handshake == null
            ? CoreConnectionState.connecting
            : CoreConnectionState.reconnecting,
        handshake: _current.handshake,
        attempt: _current.attempt,
      ),
    );

    final channel = await _connect(
      bridge.rpcUri,
      buildSubprotocols(bridge.token),
    );

    final peer = json_rpc.Peer(channel);
    _peer = peer;
    registerEventSink(
      peer,
      onEvent: _onEvent,
      // A frame we cannot parse is a protocol bug, not a reason to drop the
      // connection; log it and keep the window alive.
      onMalformed: (error, _) => _eventController.addError(error),
    );

    final listening = peer.listen();

    final handshake = await callTyped<HandshakeResponse>(
      peer,
      ConduitMethods.systemHandshake,
      params: HandshakeRequest(
        protocolVersion: kConduitProtocolVersion,
        clientName: 'conduit-desktop-ui',
        clientVersion: clientVersion,
        windowKind: bridge.windowKind,
        locale: locale,
      ).toJson(),
      decodeResult: HandshakeResponse.fromJson,
    );

    _emit(
      CoreConnection(
        state: CoreConnectionState.connected,
        handshake: handshake,
      ),
    );
    _lastError = null;

    // Re-declare interest. After a daemon restart the sequence counter
    // resets, so a lower number is a restart rather than a gap.
    if (_subscription.events.isNotEmpty || _subscription.scopes.isNotEmpty) {
      await _sendSubscription();
    }
    _startHeartbeat();

    try {
      await listening;
    } finally {
      _stopHeartbeat();
      _peer = null;
    }
  }

  /// Replaces this window's event interest set.
  Future<void> subscribe(EventSubscription subscription) async {
    _subscription = subscription;
    if (_peer != null && _current.isUsable) await _sendSubscription();
  }

  Future<void> _sendSubscription() => callTyped<EventSubscription>(
    _peer!,
    ConduitMethods.eventsSubscribe,
    params: _subscription.toJson(),
    decodeResult: EventSubscription.fromJson,
  );

  /// Calls a daemon method. Throws [RpcError] when not connected, so callers
  /// never silently no-op while the banner is up.
  Future<T> call<T>(
    String method, {
    Map<String, dynamic>? params,
    required T Function(Map<String, dynamic> json) decode,
  }) {
    final peer = _peer;
    if (peer == null || !_current.isUsable) {
      throw const RpcError(
        code: ConduitErrorCodes.daemonUnavailable,
        retryable: true,
      );
    }
    return callTyped<T>(peer, method, params: params, decodeResult: decode);
  }

  void _onEvent(EventEnvelope envelope) {
    if (envelope.seq > _lastSeq + 1 && _lastSeq != 0) _missedEvents = true;
    // A lower sequence means the daemon restarted and began counting again.
    if (envelope.seq < _lastSeq) _missedEvents = true;
    _lastSeq = envelope.seq;
    _eventController.add(envelope);
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) async {
      final peer = _peer;
      if (peer == null) return;
      try {
        await callTyped<PongResult>(
          peer,
          ConduitMethods.systemPing,
          decodeResult: PongResult.fromJson,
        ).timeout(heartbeatInterval * 3);
      } catch (_) {
        // A wedged event loop looks exactly like a dead socket from here.
        // Tear the peer down so the retry loop reconnects.
        unawaited(peer.close());
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// Full jitter: spreads reconnects when several windows wake together,
  /// which otherwise all hammer the daemon on the same tick.
  Duration _backoffFor(int attempt) {
    final capped = attempt.clamp(1, 6);
    final ceiling = 250 * (1 << (capped - 1));
    return Duration(
      milliseconds:
          ceiling ~/ 2 + (DateTime.now().microsecond % (ceiling ~/ 2 + 1)),
    );
  }

  void _emit(CoreConnection connection) {
    _current = connection;
    if (!_connectionController.isClosed) {
      _connectionController.add(connection);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _stopHeartbeat();
    await _peer?.close();
    await _connectionController.close();
    await _eventController.close();
  }
}
