import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/network/conduit_user_agent.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'log.dart';

/// The chat scope the terminal page uses when no chat is open, as mobile's
/// sidebar terminal does.
const String _pageScope = 'sidebar-terminal';

/// One terminal server in one scope, as a window refers to it.
final class _Handle {
  _Handle(this.server, this.scopeId);

  final TerminalServerInfo server;
  final String scopeId;

  /// Port previews already serving, by port.
  final Map<int, _Preview> previews = <int, _Preview>{};
}

/// Implements `terminal.*`, `WS /terminal/{handle}` and
/// `POST /terminal-upload`.
///
/// A window never sees a terminal's credential. It asks for a handle, and
/// the daemon adds the Open WebUI token or the server's key on everything
/// done through it: REST calls through the core's [TerminalService], the
/// shell's socket -- whose first frame is the credential -- and port
/// previews.
final class TerminalsService {
  TerminalsService(this._container, {DaemonLog? log}) : _log = log;

  final ProviderContainer _container;
  final DaemonLog? _log;
  final Map<String, _Handle> _handles = <String, _Handle>{};
  final Random _random = Random.secure();

  TerminalService _service() =>
      _container.read(terminalServiceProvider) ??
      (throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'terminals live on the server; sign in first',
      ));

  static String _scope(String scopeId) =>
      scopeId.trim().isEmpty ? _pageScope : scopeId.trim();

  // ---------------------------------------------------------------------------
  // Servers
  // ---------------------------------------------------------------------------

  Future<List<TerminalServerInfo>> _available(String scopeId) =>
      _guard(() async {
        final servers = await _service().getAvailableServers();
        return servers
            .where((s) => s.isAvailableForChatScope(_scope(scopeId)))
            .toList(growable: false);
      });

  Future<TerminalServers> servers(String scopeId) async {
    final servers = await _available(scopeId);
    final selected = resolveSelectedTerminalServerForTest(
      servers,
      _container.read(selectedTerminalIdProvider),
    );
    return TerminalServers(
      servers: <TerminalServerDto>[
        for (final server in servers)
          TerminalServerDto(
            id: server.selectionId,
            name: server.displayName,
            kind: server.kind.name,
            requiresSavedChat: server.requiresSavedChatContext,
          ),
      ],
      selectedId: selected?.selectionId,
    );
  }

  /// Selects the terminal chats send and the page opens. A direct server
  /// is also marked in the account's settings, where mobile and the web
  /// client read the choice.
  Future<TerminalServers> select(String? serverId) async {
    final servers = await _available('');
    final server = serverId == null
        ? null
        : servers.where((s) => s.selectionId == serverId).firstOrNull ??
              (throw RpcError(
                code: ConduitErrorCodes.notFound,
                debugMessage: 'no terminal server $serverId',
              ));
    await _guard(
      () => _service().updateDirectTerminalSelection(
        server != null && server.isDirect ? server.selectionId : null,
      ),
    );
    final selection = _container.read(selectedTerminalIdProvider.notifier);
    if (server == null) {
      selection.clear();
    } else {
      selection.set(server.selectionId);
    }
    return this.servers('');
  }

  // ---------------------------------------------------------------------------
  // Handles, files, ports
  // ---------------------------------------------------------------------------

  Future<TerminalAttached> attach(TerminalAttach request) async {
    final scope = _scope(request.scopeId);
    final server = (await _available(request.scopeId))
        .where((s) => s.selectionId == request.serverId)
        .firstOrNull;
    if (server == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no terminal server ${request.serverId} here',
      );
    }
    final service = _service();
    final supported = await service.isTerminalFeatureEnabled(
      server,
      sessionScopeId: scope,
    );
    final cwd = supported
        ? await _guard(() => service.getCwd(server, sessionScopeId: scope))
        : null;
    final handle = _newKey();
    _handles[handle] = _Handle(server, scope);
    return TerminalAttached(
      handle: handle,
      cwd: ensureTerminalDirectoryPath(cwd ?? '/'),
      supported: supported,
    );
  }

  _Handle _handle(String handle) =>
      _handles[handle] ??
      (throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no such terminal handle',
      ));

  /// One directory, folders first. The shell's working directory follows,
  /// as mobile's does, so the next `ls` in a new shell is there too.
  Future<TerminalListing> list(TerminalPath request) async {
    final h = _handle(request.handle);
    final service = _service();
    final path = ensureTerminalDirectoryPath(request.path);
    final entries = await _guard(
      () => service.listFiles(h.server, path, sessionScopeId: h.scopeId),
    );
    unawaited(
      service
          .setCwd(h.server, path, sessionScopeId: h.scopeId)
          .catchError((Object _) {}),
    );
    final sorted = [...entries]
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return TerminalListing(
      path: path,
      entries: <TerminalEntry>[
        for (final entry in sorted)
          TerminalEntry(
            name: entry.name,
            path: entry.path,
            directory: entry.isDirectory,
            size: entry.size,
            modifiedAtMs: entry.modifiedAt?.millisecondsSinceEpoch,
          ),
      ],
    );
  }

  Future<TerminalFileContent> read(TerminalPath request) async {
    final h = _handle(request.handle);
    final result = await _guard(
      () => _service().readFile(
        h.server,
        request.path,
        sessionScopeId: h.scopeId,
      ),
    );
    final bytes = result.bytes;
    return TerminalFileContent(
      name: result.fileName,
      contentType: result.contentType,
      text: result.text,
      base64: bytes == null ? null : base64Encode(bytes),
    );
  }

  Future<TerminalFileContent> download(TerminalPath request) async {
    final h = _handle(request.handle);
    final file = await _guard(
      () => _service().downloadFile(
        h.server,
        request.path,
        sessionScopeId: h.scopeId,
      ),
    );
    return TerminalFileContent(
      name: file.fileName,
      contentType: file.contentType,
      base64: base64Encode(file.bytes),
    );
  }

  Future<void> fileAction(TerminalFileAction action) async {
    final h = _handle(action.handle);
    final service = _service();
    await _guard(() async {
      switch (action.op) {
        case TerminalFileOp.mkdir:
          await service.createDirectory(
            h.server,
            action.path,
            sessionScopeId: h.scopeId,
          );
        case TerminalFileOp.delete:
          await service.deleteEntry(
            h.server,
            action.path,
            sessionScopeId: h.scopeId,
          );
        case TerminalFileOp.move:
          final destination = action.destination?.trim() ?? '';
          if (destination.isEmpty) {
            throw const RpcError(
              code: ConduitErrorCodes.invalidParams,
              debugMessage: 'a move needs a destination',
            );
          }
          await service.moveEntry(
            h.server,
            action.path,
            destination,
            sessionScopeId: h.scopeId,
          );
      }
    });
  }

  Future<TerminalPorts> ports(String handle) async {
    final h = _handle(handle);
    final ports = await _guard(
      () => _service().getListeningPorts(h.server, sessionScopeId: h.scopeId),
    );
    return TerminalPorts(
      ports: <TerminalPort>[
        for (final port in ports)
          TerminalPort(port: port.port, pid: port.pid, process: port.process),
      ],
    );
  }

  /// Puts [bytes] into [directory] on the terminal's machine.
  Future<void> upload({
    required String handle,
    required String directory,
    required String name,
    required List<int> bytes,
  }) async {
    final h = _handle(handle);
    await _guard(
      () => _service().uploadBytes(
        h.server,
        directory,
        bytes,
        name,
        sessionScopeId: h.scopeId,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // The shell
  // ---------------------------------------------------------------------------

  /// Whether [handle] names a terminal, so the tunnel route can refuse
  /// before upgrading.
  bool knows(String handle) => _handles.containsKey(handle);

  /// Joins [window] to a new shell on the handle's server.
  ///
  /// The daemon opens the session, connects, and sends the credential as
  /// the first frame. After that it is a pipe: the window's keystrokes go
  /// up as binary frames, its `resize` and `ping` messages as text, and
  /// the shell's output comes back unchanged. Either end closing closes
  /// the other.
  Future<void> tunnel(String handle, WebSocketChannel window) async {
    final h = _handles[handle];
    if (h == null) {
      await window.sink.close(4404, 'no such terminal');
      return;
    }
    WebSocketChannel? upstream;
    try {
      final service = _service();
      final session = await service.createSession(
        h.server,
        sessionScopeId: h.scopeId,
      );
      final uri = service.buildWebSocketUri(h.server, session.sessionId);
      upstream = _container.read(terminalChannelConnectorProvider)(
        uri,
        kind: h.server.kind,
      );
      await upstream.ready;
      final token = h.server.isSystem
          ? _container.read(apiServiceProvider)?.authToken
          : h.server.apiKey;
      if (token == null || token.isEmpty) {
        throw StateError('no credential for this terminal');
      }
      upstream.sink.add(
        jsonEncode(
          buildTerminalWebSocketAuthPayload(
            h.server,
            token: token,
            sessionScopeId: h.scopeId,
          ),
        ),
      );
    } on Object catch (error) {
      _log?.warn('terminal connect failed: $error');
      await upstream?.sink.close();
      await window.sink.close(4502, 'could not reach the terminal');
      return;
    }
    final up = upstream;
    final done = Completer<void>();
    void finish() {
      if (done.isCompleted) return;
      done.complete();
      unawaited(up.sink.close());
      unawaited(window.sink.close());
    }

    final fromWindow = window.stream.listen(
      (message) {
        // Keystrokes are bytes; `resize` and `ping` are JSON text. Both
        // are passed on as they came.
        if (message is String || message is List<int>) {
          up.sink.add(message);
        }
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    final fromShell = up.stream.listen(
      window.sink.add,
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    await done.future;
    await fromWindow.cancel();
    await fromShell.cancel();
  }

  // ---------------------------------------------------------------------------
  // Port previews
  // ---------------------------------------------------------------------------

  /// An address for the system browser that shows [port] of the
  /// terminal's machine, through the server's proxy.
  ///
  /// Served from a listener of its own, not the daemon's port: Electron
  /// adds the daemon's token to every request for that port, and a page
  /// being previewed is whatever the user is developing. The address
  /// carries a key; the first visit swaps it for a cookie and every later
  /// request must bring it back.
  Future<TerminalPreview> previewPort(TerminalPortRef request) async {
    final h = _handle(request.handle);
    final existing = h.previews[request.port];
    if (existing != null) return TerminalPreview(url: existing.entryUrl);
    final service = _service();
    final base = service.buildPortProxyUri(h.server, request.port);
    final token = h.server.isSystem
        ? _container.read(apiServiceProvider)?.authToken
        : h.server.apiKey;
    final preview = await _Preview.start(
      upstream: base,
      token: token,
      key: _newKey(),
      log: _log,
    );
    h.previews[request.port] = preview;
    return TerminalPreview(url: preview.entryUrl);
  }

  Future<void> dispose() async {
    for (final h in _handles.values) {
      for (final preview in h.previews.values) {
        await preview.close();
      }
    }
    _handles.clear();
  }

  String _newKey() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// The server's failures as the protocol's errors.
  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on RpcError {
      rethrow;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      throw RpcError(
        code: switch (status) {
          401 || 403 => ConduitErrorCodes.unauthorized,
          404 => ConduitErrorCodes.notFound,
          400 || 409 || 422 => ConduitErrorCodes.conflict,
          null => ConduitErrorCodes.connectionFailed,
          _ => ConduitErrorCodes.serverError,
        },
        args: <String, String>{'status': '${status ?? ''}'},
        debugMessage: 'terminal request failed ($status)',
        retryable: status == null || status >= 500,
      );
    }
  }
}

/// A loopback listener that forwards to one port behind a terminal
/// server's proxy, with the credential added.
final class _Preview {
  _Preview._(this._server, this._key, this._upstream, this._token, this._log);

  /// Named for this listener: cookies are kept per host, not per port,
  /// so two previews must not share a name.
  String get _cookie => 'conduit_preview_${_server.port}';

  final HttpServer _server;
  final String _key;
  final Uri _upstream;
  final String? _token;
  final DaemonLog? _log;
  final HttpClient _client = HttpClient()
    ..userAgent = ConduitUserAgent.value
    ..autoUncompress = false;

  String get entryUrl =>
      'http://127.0.0.1:${_server.port}/.conduit-preview/$_key';

  static Future<_Preview> start({
    required Uri upstream,
    required String? token,
    required String key,
    DaemonLog? log,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final preview = _Preview._(server, key, upstream, token, log);
    server.listen((request) => unawaited(preview._handle(request)));
    return preview;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path == '/.conduit-preview/$_key') {
        // The key, once, for a cookie the rest of the visit carries.
        response.cookies.add(
          Cookie(_cookie, _key)
            ..httpOnly = true
            ..path = '/'
            ..sameSite = SameSite.strict,
        );
        response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/');
        await response.close();
        return;
      }
      final presented = request.cookies
          .where((c) => c.name == _cookie)
          .map((c) => c.value)
          .firstOrNull;
      if (presented != _key) {
        response.statusCode = HttpStatus.forbidden;
        await response.close();
        return;
      }
      final target = _upstream.replace(
        path:
            '${_upstream.path.replaceFirst(RegExp(r'/+$'), '')}'
            '${request.uri.path}',
        query: request.uri.hasQuery ? request.uri.query : null,
      );
      final forward = await _client.openUrl(request.method, target);
      request.headers.forEach((name, values) {
        if (_hopByHop.contains(name) || name == 'cookie' || name == 'host') {
          return;
        }
        for (final value in values) {
          forward.headers.add(name, value, preserveHeaderCase: true);
        }
      });
      final token = _token;
      if (token != null && token.isNotEmpty) {
        forward.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      await forward.addStream(request);
      final answer = await forward.close();
      response.statusCode = answer.statusCode;
      answer.headers.forEach((name, values) {
        if (_hopByHop.contains(name) || name == 'set-cookie') return;
        for (final value in values) {
          response.headers.add(name, value, preserveHeaderCase: true);
        }
      });
      await response.addStream(answer);
      await response.close();
    } on Object catch (error) {
      _log?.warn('port preview failed: $error');
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } on Object {
        // The response had already started; nothing more to say.
      }
    }
  }

  static const Set<String> _hopByHop = <String>{
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'content-length',
  };

  Future<void> close() async {
    _client.close(force: true);
    await _server.close(force: true);
  }
}
