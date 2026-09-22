import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth_service.dart';
import 'bootstrap.dart';
import 'core_runtime.dart';
import 'daemon_paths.dart';
import 'event_bus.dart';
import 'log.dart';
import 'rpc_session.dart';
import 'servers_service.dart';
import 'settings_service.dart';
import 'system_service.dart';

/// The loopback server the renderer talks to.
///
/// Binds `127.0.0.1:0` so the OS picks a free port and nothing is reachable
/// off-machine. The port is reported to Electron on stdout; there is no
/// fixed port to squat on or collide with.
class DaemonServer {
  DaemonServer({
    required this.config,
    required this.directories,
    required this.daemonVersion,
    required DaemonLog log,
  }) : _log = log {
    _system = SystemService(
      directories: directories,
      daemonVersion: daemonVersion,
      log: log,
      onShutdownRequested: () => stop(),
    );
  }

  final BootstrapConfig config;
  final DaemonDirectories directories;
  final String daemonVersion;
  final DaemonLog _log;

  late final SystemService _system;

  /// Set by [attachCore]. Sessions opened before it arrives answer
  /// `servers.*` and `auth.*` with `rpc.daemonUnavailable` rather than with a
  /// plausible-looking empty result.
  CoreRuntime? _core;
  ServersService? _servers;
  AuthService? _auth;
  SettingsService? _settings;

  final EventBus events = EventBus();
  final Map<String, RpcSession> _sessions = <String, RpcSession>{};
  final Random _random = Random.secure();

  HttpServer? _server;
  final Completer<void> _stopped = Completer<void>();

  /// Resolves when the daemon has finished shutting down.
  Future<void> get onStopped => _stopped.future;

  int get port => _server?.port ?? 0;

  /// Live sessions. Exposed for the heartbeat watchdog and for tests.
  Iterable<RpcSession> get sessions => _sessions.values;

  Future<int> start() async {
    final handler = const shelf.Pipeline()
        .addMiddleware(_authGate())
        .addHandler(_route);
    _server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
    _log.info('listening on 127.0.0.1:${_server!.port}');
    return _server!.port;
  }

  /// Hands the running core to this server.
  ///
  /// Separate from [start] because the socket has to be listening before the
  /// core finishes booting: Electron needs the port on stdout to open its
  /// window, and the core's startup includes reading a database off disk.
  /// Sessions that connect in between are real sessions -- they can
  /// handshake and ping -- they simply cannot reach state that does not
  /// exist yet.
  void attachCore(CoreRuntime core) {
    _core = core;
    _servers = ServersService(core.container);
    _auth = AuthService(core.container);
    _settings = SettingsService(core.container);
    _log.info('core attached');
  }

  /// Rejects anything that is not the Electron renderer, before routing.
  ///
  /// Two independent checks, because each covers a gap in the other:
  ///
  /// * **Origin** stops a page in a real browser from opening a socket. The
  ///   browser sets it and will not let script forge it.
  /// * **Token** stops any other local process, which can set any header it
  ///   likes but cannot read a secret passed to us on stdin.
  ///
  /// `shelf_web_socket`'s own `allowedOrigins` is not used: it only checks
  /// `Origin` when the header is present, so a non-browser client passes by
  /// omitting it. Here a missing `Origin` on `/rpc` is a rejection.
  shelf.Middleware _authGate() => (shelf.Handler inner) {
    return (shelf.Request request) async {
      final path = '/${request.url.path}';
      final isWebSocketRoute =
          path == ConduitHttpRoutes.rpc || path.startsWith('/terminal/');

      if (isWebSocketRoute) {
        if (!isAllowedOrigin(request.headers['origin'])) {
          _log.warn('rejected $path: bad origin ${request.headers['origin']}');
          return shelf.Response.forbidden('invalid origin');
        }
        // Shelf joins repeated headers with ", "; the browser sends the
        // subprotocol list that way too.
        final offered = (request.headers['sec-websocket-protocol'] ?? '')
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty);
        final presented = extractSessionToken(offered);
        if (presented == null ||
            !constantTimeEquals(presented, config.sessionToken)) {
          _log.warn('rejected $path: bad or missing session token');
          return shelf.Response.forbidden('invalid session token');
        }
        return inner(request);
      }

      // Plain HTTP endpoints carry the token in a header, which Electron main
      // injects for renderer requests so `<img src>` and `<audio src>` work.
      final authorization = request.headers['authorization'] ?? '';
      const scheme = 'Bearer ';
      if (!authorization.startsWith(scheme) ||
          !constantTimeEquals(
            authorization.substring(scheme.length),
            config.sessionToken,
          )) {
        _log.warn('rejected $path: bad or missing bearer token');
        return shelf.Response.unauthorized('invalid session token');
      }
      return inner(request);
    };
  };

  Future<shelf.Response> _route(shelf.Request request) async {
    final path = '/${request.url.path}';
    if (path == ConduitHttpRoutes.rpc) return _rpcHandler(request);
    if (path == '/health') {
      // Authenticated liveness probe for the Electron supervisor; it does not
      // reveal anything a holder of the token cannot already ask for on /rpc.
      return shelf.Response.ok(
        jsonEncode(<String, Object>{
          'ok': true,
          'protocolVersion': kConduitProtocolVersion,
          'daemonVersion': daemonVersion,
          'sessions': _sessions.length,
        }),
        headers: <String, String>{'content-type': 'application/json'},
      );
    }
    return shelf.Response.notFound('no such endpoint');
  }

  late final shelf.Handler _rpcHandler = webSocketHandler(
    (WebSocketChannel socket, String? subprotocol) {
      final sessionId = _newSessionId();
      final session = RpcSession(
        sessionId: sessionId,
        // `Peer` wants a channel of strings. The protocol is text-only, so
        // `StreamChannel.cast` is the whole adaptation; a binary frame would
        // throw here, which is the correct response to a client speaking
        // something other than JSON-RPC.
        channel: socket.cast<String>(),
        system: _system,
        events: events,
        log: _log,
        servers: _servers,
        auth: _auth,
        settings: _settings,
      );
      _sessions[sessionId] = session;
      _log.debug('session $sessionId opened (subprotocol: $subprotocol)');

      unawaited(
        session
            .listen()
            .catchError((Object error, StackTrace stack) {
              _log.error('session $sessionId failed', error, stack);
            })
            .whenComplete(() {
              _sessions.remove(sessionId);
              events.detach(sessionId);
              _log.debug('session $sessionId closed');
            }),
      );
    },
    // Only the version tag is echoed back. Never the token entry: response
    // headers land in proxy logs and devtools.
    protocols: const <String>{negotiatedSubprotocol},
    // Protocol-level keepalive, so a renderer that dies without closing the
    // socket is reaped instead of holding a session forever.
    pingInterval: const Duration(seconds: 5),
  );

  String _newSessionId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Closes every session and the listening socket. Safe to call twice.
  Future<void> stop() async {
    if (_stopped.isCompleted) return;
    _log.info('stopping');
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
    // After the sockets, so nothing can arrive mid-teardown and read a
    // half-disposed container; before completing, so a caller awaiting
    // `onStopped` knows the database is closed and the process can exit.
    await _core?.dispose();
    _core = null;
    _servers = null;
    _auth = null;
    _settings = null;
    if (!_stopped.isCompleted) _stopped.complete();
  }
}
