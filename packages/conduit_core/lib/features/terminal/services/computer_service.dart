import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/computer_models.dart';
import '../models/terminal_models.dart';
import 'terminal_service.dart';

class ComputerService {
  ComputerService(this.terminal, this.server, this.scope);

  final TerminalService terminal;
  final TerminalServerInfo server;
  final String scope;
  String get chatId => isSavedTerminalChatScopeId(scope) ? scope : '';

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

  Future<ComputerConnection> open(ComputerSurface surface) async {
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
      );
    }

    return _openBrowser(await _json('browser/tabs'));
  }

  Future<ComputerConnection> _openBrowser(Map<String, dynamic> tabs) async {
    // Reattach to the agent's selected tab instead of creating a second browser.
    final current = tabs['current_session_id'];
    return current is String && current.isNotEmpty
        ? selectBrowserTab(current)
        : createBrowserTab();
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

  Future<ComputerConnection> selectBrowserTab(String id) async =>
      _connectBrowser(
        ComputerBrowserSession.fromJson(
          await _json('browser/sessions/${Uri.encodeComponent(id)}'),
        ),
      );

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
    return ComputerConnection(
      surface: ComputerSurface.browser,
      streamUri: _socketUri(
        'browser/view/${Uri.encodeComponent(selected.id)}/'
        '${Uri.encodeComponent(selected.token)}/stream',
      ),
      browserSession: selected,
      chatId: chatId,
    );
  }

  Future<void> keepAlive(ComputerConnection connection) async {
    final session = connection.browserSession;
    if (session == null) return;
    await _json(
      'browser/sessions/${Uri.encodeComponent(session.id)}',
      method: 'PATCH',
      data: <String, dynamic>{},
    );
  }

  Future<void> sendShortcut(ComputerConnection connection, String key) async {
    if (!RegExp(r'^[A-Za-z0-9_+]{1,100}$').hasMatch(key)) {
      throw const FormatException('Invalid keyboard shortcut');
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

  Future<Uint8List> screenshot(ComputerConnection connection) async {
    final response = await terminal.requestComputer(
      server,
      connection.surface == ComputerSurface.desktop
          ? 'desktop/screenshot'
          : 'browser/screenshot',
      sessionScopeId: scope,
      responseType: ResponseType.bytes,
      queryParameters: {
        if (connection.browserSession != null)
          'session_id': connection.browserSession!.id,
      },
    );
    return Uint8List.fromList((response.data as List).cast<int>());
  }
}

class ComputerBrowserUnavailable implements Exception {
  const ComputerBrowserUnavailable();
}
