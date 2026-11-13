import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conduit_core/providers/backend_mode_providers.dart'
    show preferredBackendProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'accounts_service.dart';
import 'auth_service.dart';
import 'bootstrap.dart';
import 'core_runtime.dart';
import 'redact.dart';
import 'daemon_paths.dart';
import 'event_bus.dart';
import 'log.dart';
import 'rpc_session.dart';
import 'servers_service.dart';
import 'settings_service.dart';
import 'system_service.dart';

/// The loopback server the desktop app talks to.
///
/// Binds `127.0.0.1:0` so the OS picks a free port and nothing is reachable
/// off-machine. The port is reported to the app on stdout; there is no
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
      requestStop: requestStop,
      needsOnboarding: () async =>
          await (await _coreSoon())?.needsOnboarding() ?? false,
      flushOutbox: () async => await _core?.flushOutbox() ?? 0,
      configSnapshot: _configSnapshot,
      secrets: <String>[config.sessionToken, config.masterKey],
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

  /// Completed by [attachCore], or with null when the daemon stops first.
  /// Only waited on after [coreStarting].
  Completer<CoreRuntime?>? _coreComing;
  AccountsService? _accounts;
  ServersService? _servers;
  AuthService? _auth;
  SettingsService? _settings;

  /// What sessions see of the services above: none until [attachCore].
  CoreServices _coreServices = const CoreServices();

  final EventBus events = EventBus();
  final Map<String, RpcSession> _sessions = <String, RpcSession>{};
  final Random _random = Random.secure();

  HttpServer? _server;
  final Completer<void> _stopped = Completer<void>();
  Future<void>? _stopping;

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
  /// core finishes booting: the desktop app needs the port on stdout to
  /// connect its window, and the core's startup includes reading a database
  /// off disk.
  /// Sessions that connect in between are real sessions -- they can
  /// handshake and ping -- they simply cannot reach state that does not
  /// exist yet.
  void attachCore(CoreRuntime core) {
    _core = core;
    final coming = _coreComing;
    if (coming != null && !coming.isCompleted) coming.complete(core);
    _servers = ServersService(core.container);
    _auth = AuthService(core.container);
    _settings = SettingsService(core.container);
    _accounts = AccountsService(core.container, events: events);
    // Every session reads this, including one that connected before now.
    _coreServices = CoreServices(
      accounts: _accounts,
      servers: _servers,
      auth: _auth,
      settings: _settings,
    );
    // An MCP sign-in opens the provider's page through a window.
    core.openUrl.attach(events);
    _log.info('core attached');
  }

  /// Says the core is on its way, so a handshake made before it attaches
  /// waits for it (up to 3 s) rather than answer `needsOnboarding` with
  /// "nobody knows yet".
  ///
  /// The app connects the moment it reads the ready line, which is before
  /// the core has read its storage, so without this the first handshake of
  /// nearly every launch would get that non-answer.
  void coreStarting() {
    if (_core != null) return;
    _coreComing ??= Completer<CoreRuntime?>();
  }

  /// The core, waiting for it a little while it is starting.
  Future<CoreRuntime?> _coreSoon() async {
    final core = _core;
    if (core != null) return core;
    final coming = _coreComing;
    if (coming == null) return null;
    return coming.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
  }

  /// Rejects anything that is not the desktop app, before routing.
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

      // A preflight, which is what the renderer's upload triggers: it
      // sends `Authorization` and `x-conduit-filename`, and any header
      // beyond the safelisted ones makes the browser ask permission first.
      //
      // Answered before the token check, and it has to be: a preflight
      // never carries the request's headers, so demanding the token here
      // would reject the question that asks whether the token is allowed.
      // That is not a hole -- a preflight reveals only what this endpoint
      // accepts, the `Origin` is still pinned to the app, and the real
      // request that follows is checked below like any other.
      if (request.method == 'OPTIONS') {
        if (!isAllowedOrigin(request.headers['origin'])) {
          return shelf.Response.forbidden('invalid origin');
        }
        return shelf.Response.ok(null, headers: _corsHeaders);
      }

      // Plain HTTP endpoints carry the token in an `Authorization` header,
      // which the desktop app sends with every request it makes here.
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

  /// What the renderer is allowed to send, and nothing wider.
  ///
  /// The origin is named rather than `*`: `app://conduit` is the only page
  /// that may reach this daemon at all, and a wildcard would additionally
  /// let any website's script read the responses if one ever found the
  /// port.
  static const Map<String, String> _corsHeaders = <String, String>{
    'access-control-allow-origin': kConduitAppOrigin,
    'access-control-allow-methods': 'POST, GET, OPTIONS',
    'access-control-allow-headers':
        'authorization, content-type, '
        'x-conduit-filename, x-conduit-terminal, x-conduit-directory',
    'access-control-max-age': '600',
  };

  Future<shelf.Response> _route(shelf.Request request) async {
    final path = '/${request.url.path}';
    if (path == ConduitHttpRoutes.rpc) return _rpcHandler(request);
    if (path == '/health') {
      // Authenticated liveness probe for a supervisor; it does not
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
        // Read on every call, so a window that connected before the core
        // attached gets the services once they exist.
        services: () => _coreServices,
        reportNetwork: (online) => _core?.reportNetwork(online: online),
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

  /// What the diagnostics export says about the core's configuration.
  ///
  /// Field by field from the wire DTOs, which already leave secrets out,
  /// and narrower still: addresses only as far as their origin, headers by
  /// name, and no account names or emails.
  Future<Map<String, Object?>> _configSnapshot() async {
    final core = _core;
    if (core == null) return <String, Object?>{'state': 'starting'};
    Future<Object?> section(Future<Object?> Function() read) async {
      try {
        return await read().timeout(const Duration(seconds: 3));
      } on Object catch (error) {
        return <String, Object?>{'error': error.runtimeType.toString()};
      }
    }

    return <String, Object?>{
      'state': 'attached',
      'preferredBackend': core.container.read(preferredBackendProvider).name,
      'accounts': await section(() async {
        final list = await _accounts!.list();
        return <String, Object?>{
          'activeAccountId': list.activeAccountId,
          'addingAccount': list.addingAccount,
          'accounts': <Map<String, Object?>>[
            for (final account in list.accounts)
              <String, Object?>{
                'id': account.id,
                'serverId': account.serverId,
                'origin': originOnly(account.connection.url),
                'isActive': account.isActive,
                'hasSession': account.hasSession,
                'allowSelfSignedCertificates':
                    account.connection.allowSelfSignedCertificates,
                'hasMutualTlsCredentials':
                    account.connection.hasMutualTlsCredentials,
                'customHeaderNames': account.connection.customHeaderNames,
              },
          ],
        };
      }),
      'auth': await section(() async {
        final auth = await _auth!.status();
        return <String, Object?>{
          'phase': auth.phase.name,
          'isAuthenticated': auth.isAuthenticated,
          'hasToken': auth.hasToken,
          'errorCode': auth.errorCode,
          'isReviewerMode': auth.isReviewerMode,
        };
      }),
      'outboxPending': await section(core.pendingOutboxCount),
      'windows': _sessions.length,
    };
  }

  String _newSessionId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Stops the daemon for [reason]: the one path stdin EOF, SIGINT/SIGTERM
  /// and `system.shutdown` all take, so each stops it the same way.
  void requestStop(String reason) {
    _log.info('stop requested: $reason');
    unawaited(stop());
  }

  /// Closes every session and the listening socket, then the core.
  ///
  /// One stop however many ask: the app closing stdin right after
  /// `system.shutdown` must not tear the core down twice, or a second time
  /// while the first is half done.
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _log.info('stopping');
    final coming = _coreComing;
    if (coming != null && !coming.isCompleted) coming.complete(null);
    for (final session in _sessions.values.toList()) {
      await session.close();
    }
    _sessions.clear();
    await _server?.close(force: true);
    _server = null;
    // The services that hold chats and watches go while the core they read
    // is still there: stopping an answer that is still running, and closing a
    // chat that lingers after its answer, both read its container.
    _accounts?.dispose();
    _accounts = null;
    // After the sockets and those, so nothing can arrive mid-teardown and
    // read a half-disposed container; before completing, so a caller
    // awaiting `onStopped` knows the database is closed and the process can
    // exit.
    await _core?.dispose();
    _core = null;
    _servers = null;
    _auth = null;
    _settings = null;
    if (!_stopped.isCompleted) _stopped.complete();
  }
}
