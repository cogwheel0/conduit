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
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The server's own terminal ("box") behind a sign-in proxy, and the
/// Computer view of a chat's terminal, across an account change. The server
/// answers from loopback; every name in it is invented.
void main() {
  late _GatedServer server;
  late ApiService api;
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
    account = Object();
    container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => api),
        isAuthenticatedProvider2.overrideWithValue(true),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        computerEnabledProvider.overrideWithValue(true),
        selectedTerminalIdProvider.overrideWith(_Box.new),
      ],
    );
    addTearDown(container.dispose);
  });

  void switchAccount() {
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    container.read(openWebUiAuthSessionEpochProvider);
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
  _GatedServer._(this._server);

  final HttpServer _server;
  final Completer<void> refusedSocket = Completer<void>();
  final Completer<void> desktopAsked = Completer<void>();
  final List<Object?> shortcuts = <Object?>[];
  Completer<void>? desktopHold;

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_GatedServer> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _GatedServer._(http);
    http.listen((request) => unawaited(server._handle(request)));
    return server;
  }

  Future<void> close() => _server.close(force: true);

  bool _let(HttpRequest request) =>
      request.headers.value('x-gate') == 'open' &&
      request.cookies.any((c) => c.name == 'gate' && c.value == 'pass');

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    final socket = WebSocketTransformer.isUpgradeRequest(request);
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
    Object? body;
    switch ((request.method, path)) {
      case ('GET', '/api/v1/users/user/settings'):
        body = <String, dynamic>{};
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
