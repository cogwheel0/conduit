import 'dart:async';

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
///   a restart of the Dart side) and `closed` when a session ends however it
///   ended, so the client opens another.
/// * `conduit/protocol/rpc` (strings): `<session>\n<JSON-RPC message>`
///   either way. The reply is the acknowledgement the host counts (an empty
///   string); a message for a session that is gone is answered `closed`.
/// * `conduit/protocol/bytes` (binary): [ByteFrame]s either way, answered
///   when taken. The calling contract is [InProcessProtocolHost.receiveBytes]'s.
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
  Future<InProcessProtocolHost>? _host;
  bool _disposed = false;

  static final Map<String, Object> _ready = <String, Object>{
    'op': 'ready',
    'protocolVersion': kConduitProtocolVersion,
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
    _control.setMessageHandler(null);
    _rpc.setMessageHandler(null);
    _bytes.setMessageHandler(null);
    final host = _host;
    _host = null;
    if (host != null) await (await host).dispose();
  }

  Future<InProcessProtocolHost> _started() => _host ??= _start();

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
      case 'open' when session is String && session.isNotEmpty:
        return _open(session);
      case 'close' when session is String:
        await _sessions[session]?.close();
        return const <String, Object>{'ok': true};
    }
    return const <String, Object>{'error': 'no such request'};
  }

  Future<Object?> _open(String id) async {
    if (_disposed) return const <String, Object>{'error': 'stopped'};
    try {
      final host = await _started();
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
    final host = await _started();
    await host.receiveBytes(
      frame.buffer.asUint8List(frame.offsetInBytes, frame.lengthInBytes),
    );
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
