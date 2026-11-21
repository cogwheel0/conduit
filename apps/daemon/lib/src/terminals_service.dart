import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conduit_core/features/terminal/controllers/terminal_events_watcher.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_port_preview.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/network/conduit_user_agent.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/server_tls_http_client_factory.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:crypto/crypto.dart' show sha1;
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'event_bus.dart';
import 'log.dart';
import 'terminal_model_scope.dart';

/// The chat scope the terminal page uses when no chat is open, as mobile's
/// sidebar terminal does.
const String _pageScope = 'sidebar-terminal';

/// What one operation's sockets use, read once at its start: the account
/// session, its terminal service (which gives the address) and, for the
/// server's own terminals, the sign-in proxy's headers and cookies and the
/// server's TLS client. The address and the credentials therefore always
/// come from the same account.
final class _Link {
  _Link(this.account, this.service, this.headers, this.client);

  final Object account;
  final TerminalService service;
  final Map<String, String> headers;
  final HttpClient? client;
}

/// One terminal server in one scope, as a window refers to it.
final class _Handle {
  _Handle(this.server, this.scopeId, this.features);

  final TerminalServerInfo server;
  final String scopeId;
  final TerminalServerFeatures features;

  /// Port previews already serving, by port.
  final Map<int, PortPreview> previews = <int, PortPreview>{};

  /// The events sockets keeping the watched directory and the ports live
  /// (`terminal.watch`): files first, then ports. Empty until watched.
  final List<TerminalEventsWatcher> watchers = <TerminalEventsWatcher>[];

  Future<void> close() async {
    for (final watcher in watchers) {
      watcher.stop();
    }
    watchers.clear();
    for (final preview in previews.values) {
      await preview.close();
    }
    previews.clear();
  }
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
  /// [modelFor] is the model a turn in a chat (null: a new chat) runs with,
  /// which a terminal made per model is used for.
  TerminalsService(
    this._container, {
    DaemonLog? log,
    EventBus? events,
    Future<String> Function(String? chatId)? modelFor,
  }) : _log = log,
       _events = events,
       _modelFor = modelFor {
    // A handle, and every preview and watch it opened, belongs to the
    // account it was attached under: a system terminal's base and its token
    // are that account's. When the account changes they go, so an old handle
    // cannot pair one account's server with another's token, and no preview
    // goes on sending a credential after its sign-out.
    _accountWatch = _container.listen<Object?>(
      openWebUiAuthSessionEpochProvider,
      (previous, next) => unawaited(_closeHandles()),
    );
  }

  final ProviderContainer _container;
  final DaemonLog? _log;
  final EventBus? _events;
  final Future<String> Function(String? chatId)? _modelFor;
  late final ProviderSubscription<Object?> _accountWatch;
  final Map<String, _Handle> _handles = <String, _Handle>{};
  final Random _random = Random.secure();

  /// The client the server's own terminals' sockets go through, made for
  /// the server's settings it was made with.
  (ServerConfig, HttpClient)? _systemClient;

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

  /// Every server the account's chats may use, those that need a saved chat
  /// among them.
  Future<List<TerminalServerInfo>> _chatServers() => _guard(() async {
    final servers = await _service().getAvailableServers();
    return servers.where((s) => s.chatContextAvailable).toList(growable: false);
  });

  /// The servers usable in [scopeId]: a chat, or the page with none. One
  /// made per model is used for the chat's model (the page's: New Chat's).
  Future<List<TerminalServerInfo>> _available(String scopeId) async {
    final scope = _scope(scopeId);
    return [
      for (final server in await _forModel(await _chatServers(), scope))
        if (server.isAvailableForChatScope(scope)) server,
    ];
  }

  Future<List<TerminalServerInfo>> _forModel(
    List<TerminalServerInfo> servers,
    String scope,
  ) => withTerminalModel(servers, _modelFor, scope, log: _log);

  /// Every server the account's chats may use, for the window's page and
  /// composer. One made per model goes with New Chat's model; while New Chat
  /// has none ([TerminalServerInfo.needsModel]) it is left to saved chats,
  /// each with its own.
  Future<List<TerminalServerInfo>> _windowServers() async {
    final servers = await _chatServers();
    if (!servers.any((s) => s.requiresModelContext)) return servers;
    final modelId = await terminalModelIn(_modelFor, _pageScope, log: _log);
    return [for (final server in servers) server.forModel(modelId)];
  }

  /// The servers [scopeId]'s chat may use. With none, every one the
  /// account's chats may use: the window offers one that needs a saved chat
  /// only to a saved chat, and never on the page, which opens outside any.
  Future<TerminalServers> servers(String scopeId) async {
    final servers = scopeId.trim().isEmpty
        ? await _windowServers()
        : await _available(scopeId);
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
            requiresSavedChat:
                server.requiresSavedChatContext || server.needsModel,
            device: server.isTetherDevice,
          ),
      ],
      selectedId: selected?.selectionId,
    );
  }

  /// Selects the terminal chats send and the page opens, from the chat
  /// [scopeId] (or none), which must be able to use it. A direct server is
  /// also marked in the account's settings, where mobile and the web client
  /// read the choice.
  Future<TerminalServers> select(
    String? serverId, {
    String scopeId = '',
  }) async {
    final session = _session();
    final servers = await _available(scopeId);
    // The list, and the pick from it, are the account's the request began
    // under; another one's selection is never written with them.
    _requireSession(session);
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
    _requireSession(session);
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
    final session = _session();
    final scope = _scope(request.scopeId);
    final server = (await _available(request.scopeId))
        .where((s) => s.selectionId == request.serverId)
        .firstOrNull;
    _requireSession(session);
    if (server == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no terminal server ${request.serverId} here',
      );
    }
    final service = _service();
    final features = await service.getFeatures(server, sessionScopeId: scope);
    final supported = features.terminal;
    final cwd = supported
        ? await _guard(() => service.getCwd(server, sessionScopeId: scope))
        : null;
    // Attached under another account than the one now in use: the cleanup
    // for that change has run, so this handle would outlive it.
    _requireSession(session);
    final handle = _newKey();
    _handles[handle] = _Handle(server, scope, features);
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

  /// Keeps [TerminalWatch.path] and the ports live through the terminal's
  /// events sockets, as mobile's terminal does, publishing
  /// `terminal.changed`. A server without the `events` feature is never
  /// asked; the window then refreshes on demand.
  TerminalWatching watch(TerminalWatch request) {
    final h = _handle(request.handle);
    final path = ensureTerminalDirectoryPath(request.path);
    if (!h.features.events) return const TerminalWatching();
    if (h.watchers.isNotEmpty) {
      h.watchers.first.watchPath(path);
      return TerminalWatching(live: h.watchers.any((w) => w.active));
    }
    final link = _link(h.server);
    final token = _token(h.server);
    if (token == null && h.server.isSystem) return const TerminalWatching();
    final auth = buildTerminalWebSocketAuthPayload(
      h.server,
      token: token ?? '',
      sessionScopeId: h.scopeId,
    );
    final uri = link.service.buildEventsWebSocketUri(h.server);
    // Every reconnect goes with this link: after an account change it is
    // refused (and the watch stops) rather than sent with another account's
    // credentials.
    WebSocketChannel open(Uri uri, {required TerminalServerKind kind}) =>
        _connect(h.server, uri, link);
    TerminalEventsWatcher watcher({String? path, bool ports = false}) =>
        TerminalEventsWatcher(
          openChannel: open,
          uri: uri,
          kind: h.server.kind,
          authPayload: auth,
          path: path,
          ports: ports,
          onEvent: (event) => _changed(request.handle, event),
        );
    h.watchers
      ..add(watcher(path: path))
      ..add(watcher(ports: true));
    for (final w in h.watchers) {
      w.start();
    }
    return TerminalWatching(live: h.watchers.any((w) => w.active));
  }

  void _changed(String handle, TerminalEvent event) {
    if (!_handles.containsKey(handle)) return;
    final payload = switch (event) {
      TerminalFilesChanged() => TerminalChanged(handle: handle, files: true),
      TerminalPortsChanged(:final ports) => TerminalChanged(
        handle: handle,
        ports: <TerminalPort>[
          for (final port in ports)
            TerminalPort(port: port.port, pid: port.pid, process: port.process),
        ],
      ),
    };
    _events?.emit(ConduitEventSpecs.terminalChanged, payload);
  }

  /// Lets [handle] go: its watch stops and its previews close. Unknown
  /// handles are fine (a window may detach twice).
  Future<void> detach(String handle) async {
    await _handles.remove(handle)?.close();
  }

  /// The [_Link] for an operation on [server], read now.
  _Link _link(TerminalServerInfo server) {
    final account = _session();
    final service = _service();
    if (!server.isSystem) {
      return _Link(account, service, const <String, String>{}, null);
    }
    final cookies = service.proxyCookiesForServer(server);
    return _Link(account, service, <String, String>{
      ...service.computerProxyHeadersForServer(server),
      if (cookies.isNotEmpty)
        HttpHeaders.cookieHeader: <String>[
          for (final e in cookies.entries) '${e.key}=${e.value}',
        ].join('; '),
    }, _clientFor(service.api.serverConfig));
  }

  /// A socket to [server] at [uri], which [link]'s service gave. A direct
  /// terminal's goes straight to it. The server's own terminals' go as every
  /// other request to that server does: with [link]'s sign-in proxy cookies
  /// and headers (never Open WebUI's own cookies: the socket's first frame
  /// carries the account's token) and its TLS client. Refused once another
  /// account session is in use than [link]'s.
  WebSocketChannel _connect(TerminalServerInfo server, Uri uri, _Link link) {
    _requireSession(link.account);
    if (!server.isSystem) {
      return _container.read(terminalChannelConnectorProvider)(
        uri,
        kind: server.kind,
      );
    }
    return IOWebSocketChannel.connect(
      uri,
      headers: link.headers,
      customClient: link.client,
    );
  }

  HttpClient _clientFor(ServerConfig config) {
    final kept = _systemClient;
    if (kept != null && kept.$1 == config) return kept.$2;
    kept?.$2.close();
    final client = ServerTlsHttpClientFactory.createHttpClient(config)
      ..userAgent = ConduitUserAgent.value;
    _systemClient = (config, client);
    return client;
  }

  /// The credential the daemon adds for [server]: Open WebUI's token for
  /// its own terminals, a direct terminal's key.
  String? _token(TerminalServerInfo server) => server.isSystem
      ? _container.read(apiServiceProvider)?.authToken
      : server.apiKey;

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
    // The credentials are the account's in use now, read before any await
    // with the service that gives the address: after a switch they are
    // another account's, for another server.
    final token = _token(h.server);
    WebSocketChannel? upstream;
    try {
      final link = _link(h.server);
      final session = await link.service.createSession(
        h.server,
        sessionScopeId: h.scopeId,
      );
      final uri = link.service.buildWebSocketUri(h.server, session.sessionId);
      upstream = _connect(h.server, uri, link);
      await upstream.ready;
      _requireSession(link.account);
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
      // A socket that never opened may never finish closing: the window is
      // told at once.
      final failed = upstream;
      if (failed != null) {
        unawaited(
          failed.sink.close().then<void>((_) {}, onError: (Object _) {}),
        );
      }
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
  /// Served from a listener of its own, not the daemon's port: a page being
  /// previewed is whatever the user is developing, and it must not share an
  /// origin with the routes that honour the daemon's token. The address
  /// carries a key; the first visit swaps it for a cookie and every later
  /// request must bring it back.
  ///
  /// Behind a sign-in proxy in front of Open WebUI, its own terminals'
  /// previews carry the proxy's cookies and headers as every other request
  /// to the server does (never Open WebUI's own cookies), and use the
  /// server's TLS settings.
  Future<TerminalPreview> previewPort(TerminalPortRef request) async {
    final session = _session();
    final h = _handle(request.handle);
    const scripts = <String>[terminalPreviewNavigationScript];
    final existing = h.previews[request.port];
    if (existing != null) {
      return TerminalPreview(url: existing.entryUrl, scripts: scripts);
    }
    // The port proxy's root for this port: `{terminal}/proxy/{port}/`.
    final base = TerminalPreviewNavigator.proxy(
      terminalBaseUri: h.server.baseUrl,
    ).pageUri(Uri(scheme: 'http', host: 'localhost', port: request.port));
    final service = _service();
    final preview = await PortPreview.start(
      upstream: base,
      token: _token(h.server),
      key: _newKey(),
      cookies: service.proxyCookiesForServer(h.server),
      headers: service.computerProxyHeadersForServer(h.server),
      client: h.server.isSystem
          ? ServerTlsHttpClientFactory.createHttpClient(
              service.api.serverConfig,
            )
          : null,
      log: _log,
    );
    if (!identical(session, _session()) ||
        !identical(_handles[request.handle], h)) {
      await preview.close();
      _requireSession(session);
      throw const RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no such terminal',
      );
    }
    h.previews[request.port] = preview;
    return TerminalPreview(url: preview.entryUrl, scripts: scripts);
  }

  Future<void> dispose() async {
    _accountWatch.close();
    await _closeHandles();
    _systemClient?.$2.close();
    _systemClient = null;
  }

  /// The account session now in use.
  Object _session() => _container.read(openWebUiAuthSessionEpochProvider);

  void _requireSession(Object session) {
    if (!identical(session, _session())) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed',
      );
    }
  }

  Future<void> _closeHandles() async {
    final handles = _handles.values.toList();
    _handles.clear();
    for (final h in handles) {
      await h.close();
    }
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
/// server's proxy, with the credential added: its pages, and the
/// WebSockets they open (a dev server's live reload), both ways.
///
/// The page it serves is untrusted: it may only reach its own port. So a
/// path that could climb out of the port's proxy is refused, a redirect is
/// handed to the browser rather than followed with the credential (one in
/// answer to a WebSocket is refused), and a state-changing request or a
/// WebSocket from another page on this computer is refused.
final class PortPreview {
  PortPreview._(
    this._server,
    this._key,
    this._upstream,
    this._token,
    this._cookies,
    this._headers,
    HttpClient? client,
    this._log,
  ) : _client = (client ?? HttpClient())
        ..userAgent = ConduitUserAgent.value
        ..autoUncompress = false;

  /// Named for this listener: cookies are kept per host, not per port,
  /// so two previews must not share a name.
  String get _cookie => 'conduit_preview_${_server.port}';

  final HttpServer _server;
  final String _key;
  final Uri _upstream;
  final String? _token;

  /// A sign-in proxy's cookies (by name) and headers, for Open WebUI's own
  /// terminals behind one; empty otherwise.
  final Map<String, String> _cookies;
  final Map<String, String> _headers;
  final DaemonLog? _log;
  final HttpClient _client;

  /// The upstream's path prefix (`/api/v1/terminals/{id}/proxy/{port}`),
  /// without its trailing slash.
  String get _prefix => _upstream.path.replaceFirst(RegExp(r'/+$'), '');

  String get entryUrl =>
      'http://127.0.0.1:${_server.port}/.conduit-preview/$_key';

  static Future<PortPreview> start({
    required Uri upstream,
    required String? token,
    required String key,
    Map<String, String> cookies = const <String, String>{},
    Map<String, String> headers = const <String, String>{},
    HttpClient? client,
    DaemonLog? log,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final preview = PortPreview._(
      server,
      key,
      upstream,
      token,
      cookies,
      headers,
      client,
      log,
    );
    server.listen((request) => unawaited(preview._handle(request)));
    return preview;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path == '/.conduit-preview/$_key') {
        // The key, once per visit, for a cookie the rest of the visit
        // carries; `to` (a path on the port) is where the visit lands.
        response.cookies.add(
          Cookie(_cookie, _key)
            ..httpOnly = true
            ..path = '/'
            ..sameSite = SameSite.strict,
        );
        response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            previewLanding(request.uri.queryParameters['to']),
          );
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
      if (!previewPathAllowed(request.uri)) {
        response.statusCode = HttpStatus.badRequest;
        await response.close();
        return;
      }
      // A WebSocket is not held to the same-origin rule by the browser, so
      // it must come from the preview's own page too.
      if (!_safeMethods.contains(request.method) ||
          WebSocketTransformer.isUpgradeRequest(request)) {
        final origin = request.headers.value('origin');
        if (origin != null && origin != _origin) {
          response.statusCode = HttpStatus.forbidden;
          await response.close();
          return;
        }
      }
      final target = _upstream.replace(
        path: '$_prefix${previewUpstreamPath(request.uri.path, _prefix)}',
        query: request.uri.hasQuery ? request.uri.query : null,
      );
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        await _tunnel(request, target);
        return;
      }
      final forward = await _client.openUrl(request.method, target);
      // A redirect goes to the browser: followed here, the credential would
      // go along to wherever it points.
      forward.followRedirects = false;
      request.headers.forEach((name, values) {
        if (_hopByHop.contains(name) ||
            name == 'cookie' ||
            name == 'host' ||
            name == 'origin' ||
            name == 'referer') {
          return;
        }
        for (final value in values) {
          forward.headers.add(name, value, preserveHeaderCase: true);
        }
      });
      _headers.forEach(forward.headers.set);
      if (_cookies.isNotEmpty) {
        forward.headers.set(
          HttpHeaders.cookieHeader,
          [for (final e in _cookies.entries) '${e.key}=${e.value}'].join('; '),
        );
      }
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
          response.headers.add(
            name,
            name == 'location'
                ? previewLocation(value, _upstream, _prefix)
                : value,
            preserveHeaderCase: true,
          );
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

  String get _origin => 'http://127.0.0.1:${_server.port}';

  static const Set<String> _safeMethods = <String>{'GET', 'HEAD', 'OPTIONS'};

  /// The page's WebSockets open now, closed with the preview.
  final Set<WebSocket> _sockets = <WebSocket>{};

  /// A WebSocket the page opens (a dev server's live reload), passed to the
  /// port as its other requests are: the same credential, a sign-in
  /// proxy's cookies and headers, and the server's TLS settings, never the
  /// page's own cookie. The port answers first: refused there, it is
  /// refused here (502), and each side's close reaches the other.
  Future<void> _tunnel(HttpRequest request, Uri target) async {
    final offered = <String>[
      for (final value in request.headers['sec-websocket-protocol'] ?? [])
        for (final p in value.split(','))
          if (p.trim().isNotEmpty) p.trim(),
    ];
    final headers = <String, String>{..._headers};
    if (_cookies.isNotEmpty) {
      headers[HttpHeaders.cookieHeader] = [
        for (final e in _cookies.entries) '${e.key}=${e.value}',
      ].join('; ');
    }
    final token = _token;
    if (token != null && token.isNotEmpty) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
    }
    final WebSocket upstream;
    try {
      upstream = await _connectUpstream(target, offered, headers);
    } on Object catch (error) {
      _log?.warn('port preview socket refused: $error');
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
      return;
    }
    final chosen = upstream.protocol;
    final WebSocket page;
    try {
      page = await WebSocketTransformer.upgrade(
        request,
        protocolSelector: chosen != null && offered.contains(chosen)
            ? (_) => chosen
            : null,
      );
    } on Object catch (error) {
      _log?.warn('port preview socket upgrade failed: $error');
      await upstream.close();
      return;
    }
    _sockets
      ..add(page)
      ..add(upstream);
    void ended() {
      _sockets
        ..remove(page)
        ..remove(upstream);
    }

    page.listen(
      upstream.add,
      onDone: () {
        unawaited(_closeSocket(upstream, page.closeCode, page.closeReason));
        ended();
      },
      onError: (Object _) => unawaited(upstream.close()),
      cancelOnError: true,
    );
    upstream.listen(
      page.add,
      onDone: () {
        unawaited(_closeSocket(page, upstream.closeCode, upstream.closeReason));
        ended();
      },
      onError: (Object _) => unawaited(page.close()),
      cancelOnError: true,
    );
  }

  /// Opens the port's side of a WebSocket. By hand rather than with
  /// [WebSocket.connect], which follows a redirect: the credential, or a
  /// sign-in proxy's headers, would go along to wherever it points (the
  /// terminal's own API, on its host). Here anything but the switch to a
  /// WebSocket is refused.
  Future<WebSocket> _connectUpstream(
    Uri target,
    List<String> offered,
    Map<String, String> headers,
  ) async {
    final nonce = base64.encode(
      List<int>.generate(16, (_) => _nonces.nextInt(256)),
    );
    final request = await _client.openUrl('GET', target);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('sec-websocket-key', nonce)
      ..set('sec-websocket-version', '13');
    if (offered.isNotEmpty) {
      request.headers.set('sec-websocket-protocol', offered.join(', '));
    }
    final response = await request.close();
    final accept = base64.encode(
      sha1.convert(utf8.encode('$nonce$_webSocketGuid')).bytes,
    );
    if (response.statusCode != HttpStatus.switchingProtocols ||
        response.headers.value('sec-websocket-accept') != accept) {
      await response.drain<void>().catchError((Object _) {});
      throw WebSocketException('the port answered ${response.statusCode}');
    }
    final protocol = response.headers.value('sec-websocket-protocol');
    final socket = await response.detachSocket();
    return WebSocket.fromUpgradedSocket(
      socket,
      protocol: protocol,
      serverSide: false,
    );
  }

  static final Random _nonces = Random.secure();

  /// RFC 6455's key suffix for `Sec-WebSocket-Accept`.
  static const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  /// Closes [socket] with [code] when it is one a peer may send, else
  /// plainly (1005 and 1006 only describe a close).
  static Future<void> _closeSocket(
    WebSocket socket,
    int? code,
    String? reason,
  ) async {
    final sendable =
        code != null &&
        (code == WebSocketStatus.normalClosure ||
            code == WebSocketStatus.goingAway ||
            (code >= 3000 && code <= 4999));
    try {
      await (sendable ? socket.close(code, reason) : socket.close());
    } on Object {
      // Already closed.
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
    for (final socket in _sockets.toList()) {
      unawaited(socket.close(WebSocketStatus.goingAway));
    }
    _sockets.clear();
    _client.close(force: true);
    await _server.close(force: true);
  }
}

/// Whether a preview may ask for [uri]'s path.
///
/// The terminal's proxy decodes the path it is given, perhaps more than
/// once, and then resolves `.` and `..`, so `/..%2F..%2Ffiles/read`, or the
/// same with `%25` in front of each escape as many times as it likes, would
/// leave the port for the terminal's own API with the credential. So the
/// path is decoded until it settles (refused if it has not within a few
/// rounds, or holds a malformed escape), split on `/` and `\`, and refused
/// when any part is `.` or `..`.
bool previewPathAllowed(Uri uri) {
  var path = uri.path;
  for (var round = 0; round < 8; round++) {
    final String decoded;
    try {
      decoded = Uri.decodeComponent(path);
    } on Object {
      return false;
    }
    if (decoded == path) {
      return !path
          .split(RegExp(r'[/\\]'))
          .any((part) => part == '.' || part == '..');
    }
    path = decoded;
  }
  return false;
}

/// Where a preview's first visit lands: [to] when it is a path on the
/// port (`/docs?page=2`), else the port's root. Never another host.
String previewLanding(String? to) {
  final path = to?.trim() ?? '';
  if (!path.startsWith('/') || path.startsWith('//') || path.contains('\\')) {
    return '/';
  }
  return path;
}

/// The path to ask the terminal's proxy for, given the [path] the preview
/// was asked for. Open WebUI rewrites a port page's root-relative links to
/// its own proxy path (`/api/v1/terminals/{id}/proxy/{port}/...`, [prefix]),
/// and the page's scripts send requests there too: those reach the preview
/// already prefixed, and lose the prefix here so it is not sent twice.
String previewUpstreamPath(String path, String prefix) {
  if (prefix.isNotEmpty && (path == prefix || path.startsWith('$prefix/'))) {
    final rest = path.substring(prefix.length);
    return rest.isEmpty ? '/' : rest;
  }
  return path;
}

/// A redirect's [location] as the preview serves it: one into the port's
/// proxy ([upstream], [prefix]) becomes a path on the preview, anything
/// else stays as it is.
String previewLocation(String location, Uri upstream, String prefix) {
  final target = upstream.resolve(location);
  final sameOrigin =
      target.scheme == upstream.scheme &&
      target.host == upstream.host &&
      target.port == upstream.port;
  if (!sameOrigin ||
      prefix.isEmpty ||
      !(target.path == prefix || target.path.startsWith('$prefix/'))) {
    return location;
  }
  final rest = target.path.substring(prefix.length);
  return '${rest.isEmpty ? '/' : rest}'
      '${target.hasQuery ? '?${target.query}' : ''}'
      '${target.hasFragment ? '#${target.fragment}' : ''}';
}
