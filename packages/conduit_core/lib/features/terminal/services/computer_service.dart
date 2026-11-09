import 'dart:io';

import 'package:dio/dio.dart';
import 'package:conduit_core/services/server_tls_http_client_factory.dart';

import '../models/computer_models.dart';
import '../models/terminal_models.dart';
import 'terminal_service.dart';

/// Chat-scoped access to advertised Open Terminal Computer surfaces.
/// Viewer credentials remain in memory and never enter chat messages.
class ComputerService {
  ComputerService(this.terminal, this.server, this.scope);

  final TerminalService terminal;
  final TerminalServerInfo server;
  final String scope;
  String get chatId => isSavedTerminalChatScopeId(scope) ? scope : '';

  HttpClient _createHttpClient() => server.isSystem
      ? ServerTlsHttpClientFactory.createHttpClient(terminal.api.serverConfig)
      : HttpClient();

  /// Returns no capabilities for HTTP 404; other request errors propagate.
  Future<ComputerCapabilities> capabilities() async {
    try {
      final response = await terminal.requestComputer(
        server,
        'api/config',
        sessionScopeId: scope,
      );
      return ComputerCapabilities.fromJson(response.data);
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return const ComputerCapabilities();
      }
      rethrow;
    }
  }

  Uri _socketUri(String path) {
    final base = server.baseUrl.toString().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/$path');
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException('Computer requires HTTP or HTTPS');
    }
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  Future<Map<String, dynamic>> _json(
    String path, {
    String method = 'GET',
    Object? data,
  }) async {
    final response = await terminal.requestComputer(
      server,
      path,
      sessionScopeId: scope,
      method: method,
      data: data,
    );
    if (response.data is! Map) {
      throw const FormatException('Invalid Computer response');
    }
    return Map<String, dynamic>.from(response.data as Map);
  }

  /// Reads an existing surface without activating or selecting tabs.
  /// An empty browser returns null; proxy connections require explicit
  /// takeover and [selectBrowserTab] before streaming. Tab creation is
  /// explicit through [createBrowserTab].
  Future<ComputerConnection?> open(ComputerSurface surface) async {
    if (surface == ComputerSurface.desktop) {
      final info = await _json('desktop');
      final transport = info['transport'] ?? 'vnc';
      if (transport != 'frames' && transport != 'vnc') {
        throw const FormatException('Unsupported desktop transport');
      }
      return ComputerConnection(
        surface: surface,
        streamUri: _socketUri('desktop/stream'),
        transport: transport as String,
        token: terminal.authTokenForServer(server) ?? '',
        chatId: chatId,
        audioAvailable: info['audio'] == true,
        proxyCookies: terminal.proxyCookiesForServer(server),
        proxyHeaders: terminal.computerProxyHeadersForServer(server),
        createHttpClient: _createHttpClient,
      );
    }

    // Viewing or refreshing an empty browser must never create a tab.
    var tabs = await _json('browser/tabs');
    var rechecked = false;
    while (true) {
      final current = tabs['current_session_id'];
      if (current is! String || current.isEmpty) return null;
      try {
        final session = ComputerBrowserSession.fromJson(
          await _json('browser/sessions/${Uri.encodeComponent(current)}'),
        );
        return _browserConnection(session);
      } on DioException catch (error) {
        if (error.response?.statusCode != 404 || rechecked) rethrow;
        rechecked = true;
        // The agent may have closed this tab. A removed server still fails
        // the fresh listing; do not misrepresent it as an empty browser.
        tabs = await _json('browser/tabs');
      }
    }
  }

  Future<List<ComputerBrowserTab>> browserTabs() async {
    final response = await _json('browser/tabs');
    final tabs = response['tabs'];
    if (tabs is! List) throw const FormatException('Invalid browser tabs');
    return tabs
        .map(
          (tab) => ComputerBrowserTab.fromJson(
            Map<String, dynamic>.from(tab as Map),
          ),
        )
        .toList(growable: false);
  }

  /// Selects the tab and activates Chrome mode, changing server state.
  /// Throws [ComputerBrowserUnavailable] if the session cannot use Chrome.
  Future<ComputerConnection> selectBrowserTab(String id) async =>
      _connectBrowser(
        ComputerBrowserSession.fromJson(
          await _json('browser/sessions/${Uri.encodeComponent(id)}'),
        ),
      );

  /// Creates and selects a Chrome tab, cleaning up if activation fails.
  Future<ComputerConnection> createBrowserTab() async {
    final session = ComputerBrowserSession.fromJson(
      await _json('browser/sessions', method: 'POST', data: {'url': ''}),
    );
    try {
      return await _connectBrowser(session);
    } catch (_) {
      // Failed Chrome startup must not consume the server's tab limit.
      try {
        await closeBrowserTab(session.id);
      } catch (_) {
        /* Keep the original error. */
      }
      rethrow;
    }
  }

  Future<void> closeBrowserTab(String id) async {
    await _json(
      'browser/sessions/${Uri.encodeComponent(id)}',
      method: 'DELETE',
    );
  }

  Future<ComputerConnection> _connectBrowser(
    ComputerBrowserSession session,
  ) async {
    if (!session.chromeAvailable) {
      throw const ComputerBrowserUnavailable();
    }
    final selected = ComputerBrowserSession.fromJson(
      await _json(
        'browser/sessions/${Uri.encodeComponent(session.id)}',
        method: 'PATCH',
        data: {'mode': 'chrome', 'active': true},
      ),
    );
    return _browserConnection(selected);
  }

  ComputerConnection _browserConnection(ComputerBrowserSession selected) {
    if (!selected.chromeAvailable) throw const ComputerBrowserUnavailable();
    return ComputerConnection(
      surface: ComputerSurface.browser,
      streamUri: _socketUri(
        'browser/view/${Uri.encodeComponent(selected.id)}/'
        '${Uri.encodeComponent(selected.token)}/stream',
      ),
      browserSession: selected,
      proxyCookies: terminal.proxyCookiesForServer(server),
      proxyHeaders: terminal.computerProxyHeadersForServer(server),
      createHttpClient: _createHttpClient,
      chatId: chatId,
    );
  }

  /// Renews the server's current tab without changing selection. Touching a
  /// previously watched session can otherwise win an inactive-tab selection tie.
  Future<void> keepAlive(ComputerConnection connection) async {
    if (connection.browserSession == null) return;
    await _json('browser/tabs');
  }

  /// Sends a named key combination to the displayed surface and chat scope.
  Future<void> sendShortcut(ComputerConnection connection, String key) async {
    if (!RegExp(r'^[A-Za-z0-9_+]{1,100}$').hasMatch(key)) {
      throw const FormatException('Invalid keyboard shortcut');
    }
    // Uppercase letters imply Shift in the Linux desktop backend. Modifiers
    // must be explicit: Ctrl+S means save, while Ctrl+Shift+S means Save As.
    if (key.contains('+')) {
      key = key
          .split('+')
          .map((part) => part.length == 1 ? part.toLowerCase() : part)
          .join('+');
    }
    await terminal.requestComputer(
      server,
      connection.surface == ComputerSurface.desktop
          ? 'desktop/action'
          : 'browser/action',
      sessionScopeId: scope,
      method: 'POST',
      responseType: ResponseType.bytes,
      data: {
        if (connection.browserSession != null)
          'session_id': connection.browserSession!.id,
        'actions': [
          {'action': 'key', 'key': key},
        ],
      },
    );
  }
}

class ComputerBrowserUnavailable implements Exception {
  const ComputerBrowserUnavailable();
}
