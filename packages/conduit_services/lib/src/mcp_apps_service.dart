import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/mcp_apps/mcp_app_document.dart';
import 'package:conduit_core/features/mcp_apps/mcp_app_host.dart';
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'event_bus.dart';
import 'ui_requests_service.dart';

/// MCP Apps in Open WebUI chats, hosted here with the core's [McpAppHost],
/// as the mobile app hosts them (`McpAppEmbed`); the window only draws the
/// page in a sealed web view and passes its messages along.
///
/// `mcpApps.open` reads the app's page through the server's app RPC, which
/// accepts only the binding it signed for the server and tool, and starts a
/// host for it. The page's messages come in with `mcpApps.message`; the
/// host's go out as `mcpApps.event`, scoped to the chat, with the page's
/// height and its start. Every tool the app calls, and every page it asks
/// to open, is put to the user first (`ui.request`); an app that has not
/// started within [startTimeout] is closed. An app the server sends no
/// security policy for is refused, as on mobile.
final class McpAppsService {
  McpAppsService(
    this._container,
    this._events, {
    UiRequestsService? uiRequests,
    this.startTimeout = const Duration(seconds: 30),
  }) : _uiRequests = uiRequests {
    // Another account's apps are not this one's to run: a new client, or
    // a new sign-in on the same one.
    _session = _container.listen<ApiService?>(apiServiceProvider, (
      previous,
      next,
    ) {
      if (!identical(previous, next)) closeAll();
    });
    _epoch = _container.listen<Object>(openWebUiAuthSessionEpochProvider, (
      previous,
      next,
    ) {
      if (!identical(previous, next)) closeAll();
    });
  }

  final ProviderContainer _container;
  final EventBus _events;
  final UiRequestsService? _uiRequests;

  /// How long an app has to finish its handshake.
  final Duration startTimeout;

  late final ProviderSubscription<ApiService?> _session;
  late final ProviderSubscription<Object> _epoch;
  final Map<String, _Running> _running = <String, _Running>{};

  static const Uuid _uuid = Uuid();

  /// The most an app's page may ask to be, in points.
  static const double maxHeight = 1600;

  /// `mcpApps.open`.
  Future<McpAppSession> open(McpAppOpen request) async {
    // The account the app runs for, before any await.
    final session = _container.read(openWebUiAuthSessionEpochProvider);
    final api = _container.read(apiServiceProvider);
    bool current() =>
        identical(api, _container.read(apiServiceProvider)) &&
        identical(session, _container.read(openWebUiAuthSessionEpochProvider));
    if (api == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'MCP Apps need an Open WebUI account',
      );
    }
    final app = OpenWebUiMcpApp(
      serverId: request.app.serverId,
      toolName: request.app.toolName,
      binding: request.app.binding,
      arguments: _object(request.app.arguments),
      result: _object(request.app.result),
    );
    final OpenWebUiMcpAppResource resource;
    try {
      resource = OpenWebUiMcpAppResource.fromJson(
        await api.runMcpAppRequest(app, method: 'ui/resource'),
      );
    } on McpAppRpcException catch (error) {
      // The server's own reason ("Invalid app binding. Run the tool
      // again."), for the card to show.
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        args: <String, String>{'detail': error.message},
        debugMessage: error.message,
      );
    }
    // Read under one account, it is never started under the next: that
    // account's apps were closed when it changed.
    if (!current()) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed while the app was read',
      );
    }
    final appId = _uuid.v4();
    final running = _Running(
      chatId: request.chatId,
      theme: request.theme,
      locale: request.locale,
      width: request.width,
    );
    running.host = McpAppHost(
      app: app,
      resource: resource,
      runRequest: (method, params) =>
          api.runMcpAppRequest(app, method: method, params: params),
      confirmToolCall: (name, arguments) async =>
          await _uiRequests?.askMcpAppToolCall(
            serverName: app.serverId,
            toolName: name,
            argumentsJson: const JsonEncoder.withIndent(
              '  ',
            ).convert(arguments),
            until: running.stopped.future,
          ) ??
          false,
      openLink: (url) async {
        final asked =
            await _uiRequests?.askMcpAppOpenLink(
              url: url.toString(),
              until: running.stopped.future,
            ) ??
            false;
        // Allowed after the app closed or the account changed: nothing
        // opens.
        final allowed =
            asked && identical(_running[appId], running) && current();
        if (allowed) {
          _events.emit(
            ConduitEventSpecs.openUrl,
            OpenUrl(url: url.toString()),
          );
        }
        return allowed;
      },
      send: (message) =>
          _emit(appId, McpAppEventKind.deliver, message: message),
      hostContext: () => <String, dynamic>{
        'theme': running.theme,
        'platform': 'desktop',
        'displayMode': 'inline',
        'availableDisplayModes': const <String>['inline'],
        'locale': running.locale,
        'deviceCapabilities': const <String, bool>{
          'touch': false,
          'hover': true,
        },
        'containerDimensions': <String, double>{
          if (running.width > 0) 'width': running.width,
          'maxHeight': maxHeight,
        },
      },
      onSizeChanged: (height) => _emit(
        appId,
        McpAppEventKind.resize,
        height: height.clamp(0, maxHeight).toDouble(),
      ),
      onInitialized: () {
        running.startTimer?.cancel();
        _emit(appId, McpAppEventKind.started);
      },
      hostName: 'Conduit',
    );
    _running[appId] = running;
    running.startTimer = Timer(startTimeout, () {
      final host = running.host;
      if (host == null || host.initialized) return;
      _emit(appId, McpAppEventKind.closed);
      _stop(appId);
    });
    return McpAppSession(
      appId: appId,
      document: mcpAppPageDocument(resource),
      connectDomains: resource.declaredDomains('connectDomains'),
      resourceDomains: resource.declaredDomains('resourceDomains'),
      frameDomains: resource.declaredDomains('frameDomains'),
    );
  }

  /// `mcpApps.message`: one message the page posted.
  Future<OkResult> message(McpAppMessage request) async {
    final host = _running[request.appId]?.host;
    if (host == null) return const OkResult(ok: false);
    try {
      await host.receive(request.payload);
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'mcp-app-message-failed',
        scope: 'daemon/mcp-apps',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return const OkResult(ok: true);
  }

  /// `mcpApps.context`: the window's appearance or the page's width.
  OkResult context(McpAppContext request) {
    final running = _running[request.appId];
    final host = running?.host;
    if (running == null || host == null) return const OkResult(ok: false);
    final changes = <String, dynamic>{};
    if (request.theme case final theme? when theme != running.theme) {
      running.theme = theme;
      changes['theme'] = theme;
    }
    if (request.width case final width? when width != running.width) {
      running.width = width;
      changes['containerDimensions'] = <String, double>{
        'width': width,
        'maxHeight': maxHeight,
      };
    }
    host.hostContextChanged(changes);
    return const OkResult(ok: true);
  }

  /// `mcpApps.close`: the app hears it is going, then its host stops.
  OkResult close(McpAppRef request) {
    final known = _running.containsKey(request.appId);
    _stop(request.appId);
    return OkResult(ok: known);
  }

  /// Stops every app: the account changed, or the daemon is going.
  void closeAll() {
    for (final appId in _running.keys.toList()) {
      _emit(appId, McpAppEventKind.closed);
      _stop(appId);
    }
  }

  void dispose() {
    _session.close();
    _epoch.close();
    for (final appId in _running.keys.toList()) {
      _stop(appId);
    }
  }

  void _stop(String appId) {
    final running = _running[appId];
    if (running == null) return;
    running.startTimer?.cancel();
    // A question it asked (Open Link?) goes with it.
    if (!running.stopped.isCompleted) running.stopped.complete();
    // Torn down while still listed, so its teardown notice finds its chat.
    running.host?.teardown();
    _running.remove(appId);
  }

  void _emit(
    String appId,
    McpAppEventKind kind, {
    String? message,
    double? height,
  }) {
    final chatId = _running[appId]?.chatId;
    if (chatId == null) return;
    _events.emit(
      ConduitEventSpecs.mcpAppsEvent,
      McpAppEvent(appId: appId, kind: kind, message: message, height: height),
      scope: chatId,
    );
  }

  static Map<String, dynamic> _object(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map) {
        return <String, dynamic>{
          for (final entry in decoded.entries)
            entry.key.toString(): entry.value,
        };
      }
    } on FormatException {
      // An unreadable record carries nothing.
    }
    return const <String, dynamic>{};
  }
}

final class _Running {
  _Running({
    required this.chatId,
    required this.theme,
    required this.locale,
    required this.width,
  });

  final String chatId;
  String theme;
  final String locale;
  double width;
  McpAppHost? host;
  Timer? startTimer;

  /// Completes when the app is stopped.
  final Completer<void> stopped = Completer<void>();
}
