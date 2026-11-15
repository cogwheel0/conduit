import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/terminal/services/computer_socket_relay.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';

import 'log.dart';

/// One open view: a relay the viewer page streams through.
final class _View {
  _View(this.service, this.connection, this.relay);

  final ComputerService service;
  final ComputerConnection connection;
  final ComputerSocketRelay relay;
  Timer? heartbeat;

  Future<void> close() async {
    heartbeat?.cancel();
    await relay.close();
  }
}

/// Implements `computer.*`: the Computer viewer of a chat's terminal, over
/// the core's [ComputerService] and [ComputerSocketRelay], as mobile's
/// viewer uses them.
///
/// The window gets a relay address and no credential: the relay sends the
/// viewer's auth message on with the account's token put in
/// (`injectAuth`), and adds a sign-in proxy's cookies and headers itself.
final class ComputerRpcService {
  ComputerRpcService(this._container, {DaemonLog? log}) : _log = log;

  final ProviderContainer _container;
  final DaemonLog? _log;
  final Map<String, _View> _views = <String, _View>{};
  final Random _random = Random.secure();

  /// How often a watched browser tab is renewed, as mobile's viewer does.
  static const Duration heartbeat = Duration(seconds: 45);

  bool get _enabled => _container.read(computerEnabledProvider);

  /// The chat's Computer service: the setting on, a saved chat, and a
  /// terminal selected that the chat can use. Null otherwise.
  Future<ComputerService?> _service(String chatId) async {
    final scope = chatId.trim();
    if (!_enabled || !isSavedTerminalChatScopeId(scope)) return null;
    final selected = _container.read(selectedTerminalIdProvider);
    if (selected == null) return null;
    final terminal = _container.read(terminalServiceProvider);
    if (terminal == null) return null;
    final servers = (await terminal.getAvailableServers())
        .where((s) => s.isAvailableForChatScope(scope))
        .toList(growable: false);
    final server = resolveSelectedTerminalServerForTest(servers, selected);
    if (server == null) return null;
    return ComputerService(terminal, server, scope);
  }

  Future<ComputerService> _require(String chatId) async {
    final service = await _guard<ComputerService?>(() => _service(chatId));
    if (service == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unsupported,
        debugMessage: 'no Computer for this chat',
      );
    }
    return service;
  }

  Future<ComputerStatus> status(String chatId) async {
    if (!_enabled) return const ComputerStatus();
    try {
      final service = await _service(chatId);
      if (service == null) return const ComputerStatus(enabled: true);
      final capabilities = await service.capabilities();
      return ComputerStatus(
        enabled: true,
        desktop: capabilities.desktop,
        browser: capabilities.browser,
      );
    } on Object catch (error) {
      // A terminal that cannot say offers nothing, as mobile's header.
      _log?.warn('computer status failed: ${error.runtimeType}');
      return const ComputerStatus(enabled: true);
    }
  }

  Future<ComputerView> open(ComputerOpen request) async {
    final service = await _require(request.chatId);
    final surface = request.surface == ComputerSurfaceKind.desktop
        ? ComputerSurface.desktop
        : ComputerSurface.browser;
    final ComputerConnection? connection;
    try {
      connection = await _guard<ComputerConnection?>(() {
        if (surface == ComputerSurface.browser && request.newTab) {
          return service.createBrowserTab();
        }
        final tab = request.tabId?.trim() ?? '';
        if (surface == ComputerSurface.browser && tab.isNotEmpty) {
          return service.selectBrowserTab(tab);
        }
        return service.open(surface);
      });
    } on ComputerBrowserUnavailable {
      return ComputerView(
        surface: request.surface,
        state: ComputerViewState.browserUnavailable,
      );
    }
    if (connection == null) {
      return ComputerView(
        surface: request.surface,
        state: ComputerViewState.empty,
      );
    }
    final session = connection.browserSession;
    if (connection.requiresBrowserActivation) {
      return ComputerView(
        surface: request.surface,
        state: ComputerViewState.inactive,
        tabId: session?.id,
        title: session?.title ?? '',
        url: session?.url ?? '',
      );
    }
    final live = connection;
    final relay = await ComputerSocketRelay.start(live, injectAuth: true);
    final handle = _newKey();
    final view = _View(service, live, relay);
    view.heartbeat = Timer.periodic(heartbeat, (_) {
      unawaited(
        service.keepAlive(live).catchError((Object _) {
          // The stream reports connectivity.
        }),
      );
    });
    _views[handle] = view;
    return ComputerView(
      surface: request.surface,
      handle: handle,
      streamUrl: relay.streamUri.toString(),
      transport: connection.transport,
      audio: connection.audioAvailable,
      tabId: session?.id,
      title: session?.title ?? '',
      url: session?.url ?? '',
    );
  }

  Future<ComputerTabs> tabs(String chatId) async {
    final service = await _require(chatId);
    final tabs = await _guard(service.browserTabs);
    return ComputerTabs(
      tabs: <ComputerTab>[
        for (final tab in tabs)
          ComputerTab(
            id: tab.id,
            title: tab.title,
            url: tab.url,
            selected: tab.selected,
          ),
      ],
    );
  }

  Future<void> closeTab(ComputerTabRef request) async {
    final service = await _require(request.chatId);
    await _guard(() => service.closeBrowserTab(request.tabId));
  }

  Future<void> shortcut(ComputerShortcut request) async {
    final view =
        _views[request.handle] ??
        (throw const RpcError(
          code: ConduitErrorCodes.notFound,
          debugMessage: 'no such Computer view',
        ));
    try {
      await _guard(
        () => view.service.sendShortcut(view.connection, request.key),
      );
    } on FormatException {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'not a key combination',
      );
    }
  }

  Future<void> close(String handle) async {
    await _views.remove(handle)?.close();
  }

  Future<void> dispose() async {
    for (final view in _views.values) {
      await view.close();
    }
    _views.clear();
  }

  String _newKey() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// The terminal's failures as the protocol's errors.
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
        debugMessage: 'Computer request failed ($status)',
        retryable: status == null || status >= 500,
      );
    }
  }
}
