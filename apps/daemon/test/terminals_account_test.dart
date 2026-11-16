@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// The server's own terminal ("box") behind a sign-in proxy, and the
/// Computer view of a chat's terminal, across an account change. The server
/// answers from loopback; every name in it is invented.
void main() {
  late _GatedServer server;
  late ApiService api;
  ApiService? signedIn;
  late PrimaryAccountKind primary;
  late Object account;
  late ProviderContainer container;

  setUp(() async {
    server = await _GatedServer.start();
    addTearDown(server.close);
    api = ApiService(
      serverConfig: ServerConfig(
        id: 'home',
        name: 'Home server',
        url: server.url,
        customHeaders: const <String, String>{
          'X-Gate': 'open',
          'Cookie': 'gate=pass',
        },
      ),
      workerManager: WorkerManager(),
      authToken: 'token-a',
    );
    addTearDown(api.dispose);
    signedIn = api;
    primary = PrimaryAccountKind.openWebUi;
    account = Object();
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => signedIn),
        primaryAccountKindProvider.overrideWith((ref) => primary),
        isAuthenticatedProvider2.overrideWithValue(true),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        computerEnabledProvider.overrideWithValue(true),
        selectedTerminalIdProvider.overrideWith(_Box.new),
      ],
    );
    addTearDown(container.dispose);
  });

  void switchAccount([ApiService? next]) {
    account = Object();
    if (next != null) {
      api = next;
      signedIn = next;
      container.invalidate(apiServiceProvider);
    }
    container.invalidate(openWebUiAuthSessionEpochProvider);
    container.read(openWebUiAuthSessionEpochProvider);
  }

  /// The Open WebUI account signs out (its session goes).
  void signOut() {
    signedIn = null;
    account = Object();
    container.invalidate(apiServiceProvider);
    container.invalidate(openWebUiAuthSessionEpochProvider);
    container.read(openWebUiAuthSessionEpochProvider);
  }

  /// The next account: another server behind its own sign-in proxy.
  Future<(ApiService, _GatedServer)> awayAccount() async {
    final away = await _GatedServer.start(gate: 'away-gate', cookie: 'away');
    addTearDown(away.close);
    final next = ApiService(
      serverConfig: ServerConfig(
        id: 'away',
        name: 'Away server',
        url: away.url,
        customHeaders: const <String, String>{
          'X-Gate': 'away-gate',
          'Cookie': 'gate=away',
        },
      ),
      workerManager: WorkerManager(),
      authToken: 'token-b',
    );
    addTearDown(next.dispose);
    return (next, away);
  }

  group('live terminal watches', () {
    test('go through the sign-in proxy with its header and cookie', () async {
      final events = EventBus();
      final changed = Completer<TerminalChanged>();
      events
        ..attach('window', (e) {
          if (e.event == ConduitEvents.terminalChanged &&
              !changed.isCompleted) {
            changed.complete(TerminalChanged.fromJson(e.payload));
          }
        })
        ..subscribe(
          'window',
          EventSubscription(events: <String>[ConduitEvents.terminalChanged]),
        );
      final terminals = TerminalsService(container, events: events);
      addTearDown(terminals.dispose);
      final attached = await terminals.attach(
        const TerminalAttach(serverId: 'box'),
      );
      terminals.watch(TerminalWatch(handle: attached.handle, path: '/srv'));

      // Either the watch's socket is let through and reports the ports, or
      // the proxy turns its handshake away.
      final outcome = await Future.any(<Future<Object?>>[
        changed.future,
        server.refusedSocket.future.then((_) => 'refused'),
      ]);
      check(outcome).isA<TerminalChanged>();
      check(
        (outcome as TerminalChanged).ports,
      ).isNotNull().has((p) => p.single.port, 'port').equals(8080);
    });
  });

  group('a terminal socket takes its address and credentials from one account', () {
    test('a shell asked for as the account changes sends nothing of the next '
        "account's to the last one's server", () async {
      final (next, away) = await awayAccount();
      final terminals = TerminalsService(container);
      addTearDown(terminals.dispose);
      final attached = await terminals.attach(
        const TerminalAttach(serverId: 'box'),
      );
      final hold = Completer<void>();
      server.sessionHold = hold;
      final (window, closed) = await _windowPair();
      final tunnel = terminals.tunnel(attached.handle, window);
      await server.sessionAsked.future;
      switchAccount(next);
      hold.complete();
      await tunnel;
      check(server.socketGates).not((it) => it.contains('away-gate'));
      check(away.socketGates).isEmpty();
      check(await closed).equals(4502);
    });
  });

  group('the Open WebUI account owns its terminals, with LibreChat in charge too', () {
    test('its sign-out closes its terminals and Computer views', () async {
      primary = PrimaryAccountKind.libreChat;
      container.invalidate(primaryAccountKindProvider);
      final terminals = TerminalsService(container);
      addTearDown(terminals.dispose);
      final computer = ComputerRpcService(container);
      addTearDown(computer.dispose);
      final attached = await terminals.attach(
        const TerminalAttach(serverId: 'box'),
      );
      final view = await computer.open(
        const ComputerOpen(
          chatId: 'chat-lighthouse',
          surface: ComputerSurfaceKind.desktop,
        ),
      );

      signOut();

      // The handle itself is gone, not only the account behind it.
      check(
        () => terminals.watch(
          TerminalWatch(handle: attached.handle, path: '/srv'),
        ),
      ).throws<RpcError>().has((e) => e.code, 'code').equals(
        ConduitErrorCodes.notFound,
      );
      await check(
        WebSocket.connect(
          view.streamUrl!,
          headers: <String, String>{'origin': 'http://127.0.0.1'},
        ),
      ).throws<Object>();
    });
  });

  group('Computer views belong to the account they opened under', () {
    const chat = 'chat-lighthouse';

    test('an account change closes the view and refuses its shortcuts', () async {
      final computer = ComputerRpcService(container);
      addTearDown(computer.dispose);
      final view = await computer.open(
        const ComputerOpen(chatId: chat, surface: ComputerSurfaceKind.desktop),
      );
      check(view.state).equals(ComputerViewState.live);
      await computer.shortcut(
        ComputerShortcut(handle: view.handle!, key: 'Ctrl+S'),
      );
      check(server.shortcuts).length.equals(1);

      switchAccount();

      await check(
        computer.shortcut(ComputerShortcut(handle: view.handle!, key: 'Ctrl+S')),
      ).throws<RpcError>();
      check(server.shortcuts).length.equals(1);
      // The relay is gone with the view: its address takes no viewer.
      await check(
        WebSocket.connect(
          view.streamUrl!,
          headers: <String, String>{'origin': 'http://127.0.0.1'},
        ),
      ).throws<Object>();
    });

    test('an open that the account change overtakes makes no view', () async {
      final computer = ComputerRpcService(container);
      addTearDown(computer.dispose);
      final hold = Completer<void>();
      server.desktopHold = hold;
      final open = computer.open(
        const ComputerOpen(chatId: chat, surface: ComputerSurfaceKind.desktop),
      );
      await server.desktopAsked.future;
      switchAccount();
      hold.complete();
      await check(open).throws<RpcError>(
        (e) => e.has((e) => e.code, 'code').equals(
          ConduitErrorCodes.sessionExpired,
        ),
      );
    });

    test('a new tab asked for as the account changes is not made', () async {
      final (next, _) = await awayAccount();
      final computer = ComputerRpcService(container);
      addTearDown(computer.dispose);
      final hold = Completer<void>();
      server.settingsHold = hold;
      final open = computer.open(
        const ComputerOpen(
          chatId: chat,
          surface: ComputerSurfaceKind.browser,
          newTab: true,
        ),
      );
      await server.settingsAsked.future;
      switchAccount(next);
      hold.complete();
      await check(open).throws<RpcError>(
        (e) => e.has((e) => e.code, 'code').equals(
          ConduitErrorCodes.sessionExpired,
        ),
      );
      check(server.writes).isEmpty();
    });

    test('nothing opens once the service is shut down', () async {
      final computer = ComputerRpcService(container);
      final hold = Completer<void>();
      server.desktopHold = hold;
      final open = computer.open(
        const ComputerOpen(chatId: chat, surface: ComputerSurfaceKind.desktop),
      );
      await server.desktopAsked.future;
      await computer.dispose();
      hold.complete();
      await check(open).throws<RpcError>();
    });
  });
}

final class _Box extends SelectedTerminalId {
  @override
  String? build() => 'box';
}

/// Open WebUI behind a sign-in proxy: every request, sockets included, must
/// carry the proxy's header and cookie, or the proxy answers 401.
final class _GatedServer {
  _GatedServer._(this._server, this._gate, this._cookie);

  final String _gate;
  final String _cookie;

  /// The proxy header every socket handshake came with (or null).
  final List<String?> socketGates = <String?>[];

  /// The paths of the requests that would change the terminal (POST, PATCH,
  /// DELETE), except a shell's session.
  final List<String> writes = <String>[];
  final Completer<void> sessionAsked = Completer<void>();
  final Completer<void> settingsAsked = Completer<void>();
  Completer<void>? sessionHold;
  Completer<void>? settingsHold;

  final HttpServer _server;
  final Completer<void> refusedSocket = Completer<void>();
  final Completer<void> desktopAsked = Completer<void>();
  final List<Object?> shortcuts = <Object?>[];
  Completer<void>? desktopHold;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_GatedServer> start({
    String gate = 'open',
    String cookie = 'pass',
  }) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _GatedServer._(http, gate, cookie);
    http.listen((request) => unawaited(server._handle(request)));
    return server;
  }

  Future<void> close() => _server.close(force: true);

  bool _let(HttpRequest request) =>
      request.headers.value('x-gate') == _gate &&
      request.cookies.any((c) => c.name == 'gate' && c.value == _cookie);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    final socket = WebSocketTransformer.isUpgradeRequest(request);
    if (socket) socketGates.add(request.headers.value('x-gate'));
    if (!_let(request)) {
      if (socket && !refusedSocket.isCompleted) refusedSocket.complete();
      response.statusCode = HttpStatus.unauthorized;
      await response.close();
      return;
    }
    if (socket && path == '/api/v1/terminals/box/events') {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((message) {
        final frame = jsonDecode(message as String) as Map<String, dynamic>;
        if (frame['type'] == 'subscribe' && frame['ports'] == true) {
          ws.add(
            jsonEncode(<String, dynamic>{
              'type': 'ports:change',
              'ports': <Map<String, dynamic>>[
                <String, dynamic>{'port': 8080, 'pid': 7, 'process': 'web'},
              ],
            }),
          );
        }
      });
      return;
    }
    if (socket && path.startsWith('/api/v1/terminals/box/api/terminals/')) {
      final ws = await WebSocketTransformer.upgrade(request);
      ws.listen((_) {});
      return;
    }
    if (request.method != 'GET' &&
        path != '/api/v1/terminals/box/api/terminals') {
      writes.add(path);
    }
    Object? body;
    switch ((request.method, path)) {
      case ('GET', '/api/v1/users/user/settings'):
        if (!settingsAsked.isCompleted) settingsAsked.complete();
        await settingsHold?.future;
        body = <String, dynamic>{};
      case ('POST', '/api/v1/terminals/box/api/terminals'):
        if (!sessionAsked.isCompleted) sessionAsked.complete();
        await sessionHold?.future;
        body = <String, dynamic>{'id': 'session-1'};
      case ('GET', '/api/v1/terminals/'):
        body = <Map<String, dynamic>>[
          <String, dynamic>{'id': 'box', 'name': 'Workbench'},
        ];
      case ('GET', '/api/v1/terminals/box/api/config'):
        body = <String, dynamic>{
          'features': <String, dynamic>{'terminal': false, 'events': true},
        };
      case ('GET', '/api/v1/terminals/box/desktop'):
        if (!desktopAsked.isCompleted) desktopAsked.complete();
        await desktopHold?.future;
        body = <String, dynamic>{'transport': 'frames'};
      case ('POST', '/api/v1/terminals/box/desktop/action'):
        writes.remove(path);
        shortcuts.add(jsonDecode(await utf8.decoder.bind(request).join()));
        body = <String, dynamic>{};
      default:
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}

/// A window's socket to the daemon: the daemon's end, and the close code
/// the window's end sees.
Future<(WebSocketChannel, Future<int?>)> _windowPair() async {
  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => http.close(force: true));
  final daemonSide = Completer<WebSocketChannel>();
  http.listen((request) async {
    daemonSide.complete(
      IOWebSocketChannel(await WebSocketTransformer.upgrade(request)),
    );
  });
  final viewer = await WebSocket.connect('ws://127.0.0.1:${http.port}');
  addTearDown(viewer.close);
  final closed = Completer<int?>();
  viewer.listen(
    (_) {},
    onError: (Object _) {},
    onDone: () => closed.complete(viewer.closeCode),
  );
  return (await daemonSide.future, closed.future);
}
