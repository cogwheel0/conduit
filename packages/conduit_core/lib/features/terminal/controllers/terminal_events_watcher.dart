import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/terminal_models.dart';
import '../services/terminal_service.dart';

/// Opens a socket to a terminal server: the gateway's `openChannel`.
typedef TerminalChannelOpener = WebSocketChannel Function(
  Uri uri, {
  required TerminalServerKind kind,
});

/// How long the watcher waits before its next reconnect: one second, then
/// twice as long each time, up to 30 seconds.
Duration terminalEventsRetryDelay(int attempt) {
  final seconds = math.pow(2, math.min(attempt, 5)).toInt();
  return Duration(seconds: math.min(seconds, 30));
}

/// Keeps one of a terminal's events sockets open: either the directory
/// [path], or the open ports when [ports] is set, so the file list or the
/// port list refreshes as soon as it changes rather than when the user asks.
/// Files and ports each get a socket of their own, as in the web client, so
/// a directory the terminal cannot watch (too many files for its watch
/// limit) does not stop the ports, nor a host without port discovery the
/// files.
///
/// What a closed socket means, close to Open WebUI's own client, which
/// reconnects after anything but a 4xxx close:
/// - Closed on purpose (1000, or a 4xxx code such as a refused credential or
///   a directory that cannot be watched): the watcher stops for good, and
///   the file browser keeps refreshing on demand as it always has.
/// - Closed with 1011 before it sent anything: Open Terminal's answer when
///   it cannot watch at all (no filesystem watcher, no port discovery). It
///   stops too, rather than asking again every half minute as the web
///   client does.
/// - A handshake that failed, or a socket that dropped (1006 and the like),
///   even before the first event: it reconnects, waiting longer each time,
///   so a moment without network when the terminal opens does not cost its
///   live updates. Subscribing again reports the directory as ready and
///   sends the current ports, so nothing that changed meanwhile stays stale.
/// - A socket that cannot even be made (a malformed address): it stops.
///
/// Only a terminal that reports the `events` feature gets a watcher, so a
/// server without the endpoint is not asked at all.
final class TerminalEventsWatcher {
  TerminalEventsWatcher({
    required TerminalChannelOpener openChannel,
    required Uri uri,
    required TerminalServerKind kind,
    required Map<String, dynamic> authPayload,
    String? path,
    bool ports = false,
    required void Function(TerminalEvent event) onEvent,
    Duration Function(int attempt) retryDelay = terminalEventsRetryDelay,
  }) : _openChannel = openChannel,
       _uri = uri,
       _kind = kind,
       _authPayload = authPayload,
       _path = path,
       _ports = ports,
       _onEvent = onEvent,
       _retryDelay = retryDelay;

  final TerminalChannelOpener _openChannel;
  final Uri _uri;
  final TerminalServerKind _kind;
  final Map<String, dynamic> _authPayload;
  final void Function(TerminalEvent event) _onEvent;
  final Duration Function(int attempt) _retryDelay;

  String? _path;
  final bool _ports;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
  bool _subscribed = false;
  bool _received = false;
  bool _started = false;
  bool _stopped = false;
  int _attempt = 0;

  /// Whether the watcher still connects, or will again: false once it was
  /// stopped or gave up.
  bool get active => _started && !_stopped;

  void start() {
    if (_started || _stopped) return;
    _started = true;
    _connect();
  }

  /// Watches [path] instead of the directory watched so far.
  void watchPath(String path) {
    // A ports watcher watches no directory.
    if (_path == null || path == _path) return;
    _path = path;
    final channel = _channel;
    // Before the first subscription, or between connections, the next
    // subscription already names the new path.
    if (_stopped || channel == null || !_subscribed) return;
    channel.sink.add(jsonEncode(_subscribePayload()));
  }

  void stop() {
    if (_stopped) return;
    _stopped = true;
    _retry?.cancel();
    _retry = null;
    _release();
  }

  Map<String, dynamic> _subscribePayload() =>
      buildTerminalEventsSubscribePayload(path: _path, ports: _ports);

  void _connect() {
    _retry = null;
    if (_stopped) return;
    final WebSocketChannel channel;
    try {
      channel = _openChannel(_uri, kind: _kind);
    } catch (_) {
      _stopped = true;
      return;
    }
    _channel = channel;
    _subscribed = false;
    _subscription = channel.stream.listen(
      (frame) => _handleFrame(channel, frame),
      // A failed or dropped connection ends the stream as well.
      onError: (Object _) {},
      onDone: () => _handleClosed(channel, ended: true),
    );
    channel.ready.then(
      (_) {
        if (_stopped || !identical(_channel, channel)) return;
        channel.sink
          ..add(jsonEncode(_authPayload))
          ..add(jsonEncode(_subscribePayload()));
        _subscribed = true;
      },
      onError: (Object _) => _handleClosed(channel),
    );
  }

  void _handleFrame(WebSocketChannel channel, Object? frame) {
    if (_stopped || !identical(_channel, channel)) return;
    _received = true;
    _attempt = 0;
    final event = parseTerminalEvent(frame);
    if (event != null) _onEvent(event);
  }

  /// [ended] when the socket's stream ended, which is when its close code
  /// can be read; a refused handshake has none.
  void _handleClosed(WebSocketChannel? channel, {bool ended = false}) {
    if (_stopped || !identical(_channel, channel)) return;
    final closeCode = ended ? channel?.closeCode : null;
    _release();
    final deliberate =
        closeCode != null &&
        (closeCode == 1000 || (closeCode >= 4000 && closeCode < 5000));
    final cannotWatch = closeCode == 1011 && !_received;
    if (deliberate || cannotWatch) {
      _stopped = true;
      return;
    }
    _retry = Timer(_retryDelay(_attempt++), _connect);
  }

  void _release() {
    final channel = _channel;
    final subscription = _subscription;
    _channel = null;
    _subscription = null;
    _subscribed = false;
    if (subscription != null) unawaited(subscription.cancel());
    if (channel == null) return;
    try {
      unawaited(channel.sink.close().catchError((Object _) {}));
    } catch (_) {}
  }
}
