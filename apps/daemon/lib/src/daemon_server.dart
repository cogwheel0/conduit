import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:conduit_core/services/api_service.dart'
    show FileContentTooLargeException;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth_service.dart';
import 'bootstrap.dart';
import 'chats_service.dart';
import 'composer_service.dart';
import 'direct_service.dart';
import 'mcp_service.dart';
import 'notes_service.dart';
import 'prompts_service.dart';
import 'core_runtime.dart';
import 'daemon_paths.dart';
import 'event_bus.dart';
import 'files_service.dart';
import 'log.dart';
import 'rpc_session.dart';
import 'temporary_chats.dart';
import 'ui_requests_service.dart';
import 'models_service.dart';
import 'servers_service.dart';
import 'settings_service.dart';
import 'system_service.dart';
import 'turns_service.dart';

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
  ChatsService? _chats;
  TurnsService? _turns;
  ModelsService? _models;
  FilesService? _files;
  UiRequestsService? _uiRequests;
  ComposerService? _composer;
  PromptsService? _prompts;
  DirectService? _direct;
  McpService? _mcp;
  NotesService? _notes;

  /// The broker the core asks its questions through. Exposed so tests can
  /// ask one and watch it cross the RPC boundary.
  UiRequestsService? get uiRequests => _uiRequests;

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
    final temporary = TemporaryChats();
    _chats = ChatsService(core.container, events: events, temporary: temporary);
    _files = FilesService(core.container);
    _uiRequests = UiRequestsService(events);
    _turns = TurnsService(
      core.container,
      events,
      files: _files!,
      temporary: temporary,
      uiRequests: _uiRequests,
    );
    _models = ModelsService(core.container, events: events);
    _composer = ComposerService(core.container);
    _prompts = PromptsService(core.container);
    _direct = DirectService(core.container);
    _mcp = McpService(core.container);
    _notes = NotesService(core.container, events: events);
    // An MCP sign-in opens the provider's page through a window.
    core.openUrl.attach(events);
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
        'x-conduit-filename',
    'access-control-max-age': '600',
  };

  Future<shelf.Response> _route(shelf.Request request) async {
    final path = '/${request.url.path}';
    if (path == ConduitHttpRoutes.rpc) return _rpcHandler(request);
    if (path == ConduitHttpRoutes.upload) return _upload(request);
    if (path.startsWith('/files/')) return _file(request);
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

  /// `POST /upload` -- an attachment on its way to the server (WP-3.3).
  ///
  /// The body is the file's bytes and nothing else. No multipart parsing
  /// here: both ends of this request are ours, the daemon re-wraps the
  /// bytes for Open WebUI anyway, and a parser is a surface that would earn
  /// its keep only if some other client were posting to us.
  ///
  /// The name travels in a header because a body that is *only* bytes is
  /// what lets the whole thing stream. It is percent-encoded: a header is
  /// Latin-1 by definition, and an attachment called `résumé.pdf` would
  /// otherwise be rejected by the HTTP layer before this code ran.
  Future<shelf.Response> _upload(shelf.Request request) async {
    final files = _files;
    if (files == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'POST') {
      return shelf.Response(405, body: 'POST only');
    }

    final rawName = request.headers['x-conduit-filename'];
    if (rawName == null || rawName.trim().isEmpty) {
      return _problem(
        400,
        ConduitErrorCodes.invalidParams,
        'missing x-conduit-filename',
      );
    }
    final String name;
    try {
      name = Uri.decodeComponent(rawName);
    } on FormatException {
      return _problem(
        400,
        ConduitErrorCodes.invalidParams,
        'x-conduit-filename is not percent-encoded',
      );
    }

    try {
      final bytes = await _collect(request.read());
      final uploaded = await files.upload(
        name: name,
        bytes: bytes,
        contentType: request.headers['content-type'],
      );
      return shelf.Response.ok(
        jsonEncode(uploaded.toJson()),
        headers: <String, String>{
          'content-type': 'application/json',
          ..._corsHeaders,
        },
      );
    } on RpcError catch (error) {
      final status = switch (error.code) {
        ConduitErrorCodes.unauthenticated => 401,
        ConduitErrorCodes.invalidParams => 400,
        _ => 502,
      };
      return _problem(status, error.code, error.debugMessage);
    } on Object catch (error, stack) {
      _log.error('upload failed', error, stack);
      return _problem(502, ConduitErrorCodes.serverError, 'upload failed');
    }
  }

  /// `GET /files/{serverId}/{fileId}` -- an attachment for an `<img>` (WP-3.2).
  ///
  /// Electron adds the daemon's token to the window's requests to this
  /// port, so the image tag carries no credential and the daemon still
  /// refuses anyone else.
  Future<shelf.Response> _file(shelf.Request request) async {
    final files = _files;
    if (files == null) {
      return _problem(
        503,
        ConduitErrorCodes.daemonUnavailable,
        'core starting',
      );
    }
    if (request.method != 'GET') {
      return shelf.Response(405, body: 'GET only');
    }
    final segments = request.url.pathSegments;
    if (segments.length != 3) {
      return _problem(404, ConduitErrorCodes.notFound, 'no such file');
    }
    try {
      final file = await files.download(segments[1], segments[2]);
      return shelf.Response.ok(
        file.bytes,
        headers: <String, String>{
          'content-type': file.contentType,
          // Taken as given: a file claiming to be bytes must never be read
          // as HTML because its first line looks like some.
          'x-content-type-options': 'nosniff',
          'content-disposition': 'inline',
          // Private: it is the user's file. An hour: the same image is drawn
          // every time the conversation is opened.
          'cache-control': 'private, max-age=3600',
          ..._corsHeaders,
        },
      );
    } on RpcError catch (error) {
      final status = switch (error.code) {
        ConduitErrorCodes.unauthenticated => 401,
        ConduitErrorCodes.notFound => 404,
        _ => 502,
      };
      return _problem(status, error.code, error.debugMessage);
    } on FileContentTooLargeException {
      return _problem(413, ConduitErrorCodes.invalidParams, 'file too large');
    } on Object catch (error, stack) {
      _log.error('file download failed', error, stack);
      return _problem(502, ConduitErrorCodes.serverError, 'download failed');
    }
  }

  /// The same error shape RPC uses, so the renderer has one thing to read.
  shelf.Response _problem(int status, String code, String? message) =>
      shelf.Response(
        status,
        body: jsonEncode(<String, Object?>{
          'code': code,
          'debugMessage': ?message,
        }),
        headers: <String, String>{
          'content-type': 'application/json',
          // On the error path too, or the renderer sees an opaque CORS
          // failure instead of the reason the upload was refused.
          ..._corsHeaders,
        },
      );

  static Future<Uint8List> _collect(Stream<List<int>> body) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      builder.add(chunk);
    }
    return builder.takeBytes();
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
        chats: _chats,
        turns: _turns,
        models: _models,
        uiRequests: _uiRequests,
        composer: _composer,
        prompts: _prompts,
        direct: _direct,
        mcp: _mcp,
        notes: _notes,
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
    await _turns?.dispose();
    _turns = null;
    _models = null;
    _chats?.dispose();
    _chats = null;
    if (!_stopped.isCompleted) _stopped.complete();
  }
}
