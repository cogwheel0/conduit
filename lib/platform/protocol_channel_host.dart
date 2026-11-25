import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:conduit_core/ports/paths_port.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart'
    show DaemonPaths, kConduitProtocolVersion;
import 'package:conduit_services/conduit_services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod/riverpod.dart';

import 'phone_paths_port.dart';

/// Whether this build hosts the protocol services for screens in the app's
/// own process (`--dart-define=CONDUIT_PROTOCOL_HOST=true`). Off by default.
/// Const, so with it off the host is never reached and not compiled in.
const bool kProtocolHost = bool.fromEnvironment('CONDUIT_PROTOCOL_HOST');

/// Whether the host runs: with the define, on iOS. Android has no client for
/// it yet, so the define does nothing there.
bool protocolHostRuns({
  required bool defined,
  required TargetPlatform platform,
}) => defined && platform == TargetPlatform.iOS;

/// Listens for the client in this engine, when the build hosts it. Nothing
/// is built until the client opens a session or a byte stream.
void startProtocolChannelHost(ProviderContainer container) {
  if (!protocolHostRuns(
    defined: kProtocolHost,
    platform: defaultTargetPlatform,
  )) {
    return;
  }
  ProtocolChannelHost(container: container).listen();
}

/// [InProcessProtocolHost] over platform channels, for a native client in
/// the same process (the Swift screens).
///
/// * `conduit/protocol/control` (standard codec), maps with an `op`:
///   from the client `hello` (answered with the host's `ready`), `open` and
///   `close` of a session; from the host `ready` when it starts (again after
///   a restart of the Dart side, with a `start` of its own) and `closed` when a session ends however it
///   ended, so the client opens another.
/// * `conduit/protocol/rpc` (strings): `<session>\n<JSON-RPC message>`
///   either way. The reply is the acknowledgement the host counts (an empty
///   string); a message for a session that is gone is answered `closed`.
///   A session's name has no newline, so `open` refuses one that does.
/// * `conduit/protocol/bytes` (binary): [ByteFrame]s either way, answered
///   when taken. The calling contract is [InProcessProtocolHost.receiveBytes]'s.
///
/// An `open` is answered once the host has started, and the session takes
/// messages from then: before that, one for it is answered `closed`. A
/// `close` meanwhile cancels it (answered `closed`), as stopping the host does
/// (`stopped`); a second `open` of the same session is refused (`open`).
/// A start that fails is answered `unavailable`, on a byte stream as its
/// `error` frame, and the next `open` or byte stream starts again.
///
/// A send the client does not answer (no handler: the reply is null) counts
/// as a failed send, which ends its session.
final class ProtocolChannelHost {
  ProtocolChannelHost({
    required ProviderContainer container,
    BinaryMessenger? messenger,
    PathsPort paths = const PhonePathsPort(),
    int maxUnacknowledged = 64,
  }) : _container = container,
       _paths = paths,
       _maxUnacknowledged = maxUnacknowledged,
       _control = BasicMessageChannel<Object?>(
         controlChannel,
         const StandardMessageCodec(),
         binaryMessenger: messenger,
       ),
       _rpc = BasicMessageChannel<String?>(
         rpcChannel,
         const StringCodec(),
         binaryMessenger: messenger,
       ),
       _bytes = BasicMessageChannel<ByteData?>(
         bytesChannel,
         const BinaryCodec(),
         binaryMessenger: messenger,
       );

  static const String controlChannel = 'conduit/protocol/control';
  static const String rpcChannel = 'conduit/protocol/rpc';
  static const String bytesChannel = 'conduit/protocol/bytes';

  final ProviderContainer _container;
  final PathsPort _paths;
  final int _maxUnacknowledged;
  final BasicMessageChannel<Object?> _control;
  final BasicMessageChannel<String?> _rpc;
  final BasicMessageChannel<ByteData?> _bytes;

  final Map<String, InProcessSession> _sessions = <String, InProcessSession>{};

  /// Opens waiting for the host to start, each by a token of its own: a
  /// `close` removes it, so the open ends there.
  final Map<String, Object> _opening = <String, Object>{};
  Future<InProcessProtocolHost>? _host;
  bool _disposed = false;

  /// `start` names this binding, so a client tells a second `ready` from
  /// the same one (its `hello` answered as well) from a restart of the Dart
  /// side, whose sessions are gone.
  late final Map<String, Object> _ready = <String, Object>{
    'op': 'ready',
    'protocolVersion': kConduitProtocolVersion,
    'start': Random().nextInt(1 << 32).toRadixString(16),
  };

  void listen() {
    _control.setMessageHandler(_onControl);
    _rpc.setMessageHandler(_onRpc);
    _bytes.setMessageHandler(_onBytes);
    // A client already listening learns the host is (back) up; one that is
    // not asks with `hello` once it is.
    unawaited(_control.send(_ready).then<void>((_) {}, onError: _logSend));
  }

  /// Stops listening and stops the host; the app's container stays as it
  /// was.
  Future<void> dispose() async {
    _disposed = true;
    _opening.clear();
    _control.setMessageHandler(null);
    _rpc.setMessageHandler(null);
    _bytes.setMessageHandler(null);
    final host = _host;
    _host = null;
    if (host == null) return;
    final InProcessProtocolHost started;
    try {
      started = await host;
    } on Object {
      return;
    }
    await started.dispose();
  }

  /// The host, started once. A start that fails is forgotten, so the next
  /// client starts it again.
  Future<InProcessProtocolHost> _started() {
    if (_host case final host?) return host;
    final host = _host = _start();
    unawaited(
      host.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (identical(_host, host)) _host = null;
          DebugLogger.error(
            'protocol-host-start-failed',
            scope: 'protocol/host',
            error: error,
            stackTrace: stack,
          );
        },
      ),
    );
    return host;
  }

  static const Map<String, Object> _unavailable = <String, Object>{
    'error': 'unavailable',
  };

  Future<InProcessProtocolHost> _start() async {
    final support = await _paths.applicationSupport();
    final cache = await _paths.cache();
    final version = (await PackageInfo.fromPlatform()).version;
    return InProcessProtocolHost(
      container: _container,
      system: SystemService(
        paths: DaemonPaths(
          userData: support.path,
          database: support.path,
          cache: cache.path,
          logs: (await _paths.logs()).path,
          staging: (await _paths.staging()).path,
        ),
        platform: 'ios',
        daemonVersion: version,
        // The app's process is the app's to end.
        requestStop: (reason) => DebugLogger.info(
          'a client asked the in-app host to stop',
          scope: 'protocol/host',
        ),
      ),
      window: await WindowPorts.open(),
      sendBytes: _sendFrame,
      paths: _paths,
      maxUnacknowledged: _maxUnacknowledged,
    );
  }

  Future<Object?> _onControl(Object? message) async {
    if (message is! Map) return const <String, Object>{'error': 'not a map'};
    final session = message['session'];
    switch (message['op']) {
      case 'hello':
        return _ready;
      // The RPC channel ends a session's name at its first newline.
      case 'open'
          when session is String &&
              session.isNotEmpty &&
              !session.contains('\n'):
        return _open(session);
      case 'close' when session is String:
        _opening.remove(session);
        await _sessions[session]?.close();
        return const <String, Object>{'ok': true};
    }
    return const <String, Object>{'error': 'no such request'};
  }

  Future<Object?> _open(String id) async {
    if (_disposed) return const <String, Object>{'error': 'stopped'};
    if (_opening.containsKey(id)) {
      return const <String, Object>{'error': 'open'};
    }
    final opening = Object();
    _opening[id] = opening;
    try {
      final InProcessProtocolHost host;
      try {
        host = await _started();
      } on Object {
        return _disposed
            ? const <String, Object>{'error': 'stopped'}
            : _unavailable;
      }
      if (_disposed) return const <String, Object>{'error': 'stopped'};
      if (!identical(_opening[id], opening)) {
        return const <String, Object>{'error': 'closed'};
      }
      final session = host.open(id, send: (message) => _sendRpc(id, message));
      _sessions[id] = session;
      unawaited(
        session.closed.then((_) {
          if (identical(_sessions[id], session)) _sessions.remove(id);
          if (_disposed) return;
          unawaited(
            _control
                .send(<String, Object>{'op': 'closed', 'session': id})
                .then<void>((_) {}, onError: _logSend),
          );
        }),
      );
      return const <String, Object>{'ok': true};
    } on StateError catch (error) {
      return <String, Object>{'error': error.message};
    } finally {
      if (identical(_opening[id], opening)) _opening.remove(id);
    }
  }

  Future<String?> _onRpc(String? message) async {
    final at = message?.indexOf('\n') ?? -1;
    if (message == null || at < 0) return 'malformed';
    final session = _sessions[message.substring(0, at)];
    if (session == null) return 'closed';
    session.receive(message.substring(at + 1));
    return '';
  }

  Future<void> _sendRpc(String id, String message) async {
    final reply = await _rpc.send('$id\n$message');
    if (reply == null) throw StateError('no client took the message');
  }

  Future<ByteData?> _onBytes(ByteData? frame) async {
    if (frame == null || _disposed) return null;
    final bytes = frame.buffer.asUint8List(
      frame.offsetInBytes,
      frame.lengthInBytes,
    );
    final InProcessProtocolHost host;
    try {
      host = await _started();
    } on Object {
      if (_disposed) return null;
      // Taken, and answered as the host answers a stream it cannot serve:
      // the one an `open` starts ends with an error; the rest are dropped.
      final ByteFrame decoded;
      try {
        decoded = ByteFrame.decode(bytes);
      } on FormatException {
        return ByteData(0);
      }
      if (decoded.kind == ByteFrameKind.open) {
        // Not awaited: the client may take it only after this frame is
        // taken, as with any of the host's sends.
        unawaited(
          _sendFrame(
            ByteFrame(
              decoded.stream,
              ByteFrameKind.error,
              payload: Uint8List.fromList(utf8.encode('unavailable')),
            ).encode(),
          ).then<void>((_) {}, onError: _logSend),
        );
      }
      return ByteData(0);
    }
    if (_disposed) return null;
    await host.receiveBytes(bytes);
    return ByteData(0);
  }

  Future<void> _sendFrame(Uint8List frame) async {
    final reply = await _bytes.send(ByteData.sublistView(frame));
    if (reply == null) throw StateError('no client took the frame');
  }

  static void _logSend(Object error, StackTrace stack) => DebugLogger.warning(
    'protocol-control-send-failed',
    scope: 'protocol/host',
    data: <String, Object>{'error': error.runtimeType.toString()},
  );
}
