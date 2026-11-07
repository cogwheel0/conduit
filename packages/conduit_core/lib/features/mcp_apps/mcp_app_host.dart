import 'dart:convert';

import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';

/// The MCP Apps protocol version Conduit's host speaks (SEP-1865), the one
/// Open WebUI 0.13's web client speaks through `@modelcontextprotocol/ext-apps`.
const String kMcpAppsProtocolVersion = '2026-01-26';

/// The largest message an app may send, in bytes.
const int kMcpAppMaxMessageBytes = 256 * 1024;

/// The most requests an app may have waiting on the host at once.
const int kMcpAppMaxPendingRequests = 16;

/// Runs one request through the server's app RPC.
typedef McpAppRequestRunner =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, dynamic> params,
    );

/// The host side of an MCP App in a chat: JSON-RPC 2.0 over the app's
/// `postMessage` channel, as the web client's `AppBridge` speaks it.
///
/// The app sends `ui/initialize` and gets the host's capabilities and context;
/// once it says `ui/notifications/initialized`, it is sent the tool's input
/// and result. It may then call tools of its server, which the user confirms
/// first, read and list the server's resources, ask for a link to open, and
/// report its size. Everything else is refused. Open WebUI decides what the
/// app may reach: [runRequest] goes through its RPC, which checks the app's
/// binding and the tools an app may call.
final class McpAppHost {
  McpAppHost({
    required this.app,
    required this.resource,
    required this.runRequest,
    required this.confirmToolCall,
    required this.openLink,
    required this.send,
    required this.hostContext,
    this.onSizeChanged,
    this.onInitialized,
    this.hostName = 'Conduit',
    this.hostVersion = '1',
  });

  final OpenWebUiMcpApp app;
  final OpenWebUiMcpAppResource resource;
  final McpAppRequestRunner runRequest;

  /// Asks the user whether the app may call the tool [name] with [arguments].
  final Future<bool> Function(String name, Map<String, dynamic> arguments)
  confirmToolCall;

  /// Opens a web link the app asked for, once the user agrees; false when it
  /// was not opened.
  final Future<bool> Function(Uri url) openLink;

  /// Delivers one message to the app.
  final void Function(String message) send;

  /// What the app learns of its host: theme, locale, its container's size.
  final Map<String, dynamic> Function() hostContext;

  /// The height the app's content asks for, in logical pixels.
  final void Function(double height)? onSizeChanged;

  /// Called once the app has started.
  final void Function()? onInitialized;

  final String hostName;
  final String hostVersion;

  bool _initialized = false;
  bool _closed = false;

  /// Whether the user is being asked something for the app. An app may ask
  /// one thing at a time, as in the web client, so it cannot stack prompts.
  bool _askingUser = false;
  int _pendingRequests = 0;
  int _nextRequestId = 0;

  /// Whether the app has completed its handshake.
  bool get initialized => _initialized;

  /// Handles one message from the app. A message that is not a JSON-RPC 2.0
  /// object, or one too large, is dropped.
  Future<void> receive(String payload) async {
    // The limit is in UTF-8 bytes. A string's length counts UTF-16 units, and
    // text outside ASCII takes up to three bytes for each.
    if (_closed ||
        payload.length > kMcpAppMaxMessageBytes ||
        utf8.encode(payload).length > kMcpAppMaxMessageBytes) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return;
    }
    if (decoded is! Map || decoded['jsonrpc'] != '2.0') return;
    final message = {
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
    final method = message['method'];
    final id = message['id'];
    final hasId = id is String || id is int;
    // The app's answer to a request of the host's: only the teardown, which
    // is not waited for.
    if (method is! String) return;
    final rawParams = message['params'];
    final params = rawParams is Map
        ? {for (final entry in rawParams.entries) entry.key.toString(): entry.value}
        : const <String, dynamic>{};
    if (!hasId) {
      _notification(method, params);
      return;
    }
    if (_pendingRequests >= kMcpAppMaxPendingRequests) {
      _error(id, -32000, 'Too many requests');
      return;
    }
    _pendingRequests++;
    try {
      final result = await _request(method, params);
      if (!_closed) _result(id, result);
    } on _McpAppRequestError catch (error) {
      if (!_closed) _error(id, error.code, error.message);
    } on McpAppRpcException catch (error) {
      if (!_closed) _error(id, -32000, error.message);
    } catch (_) {
      if (!_closed) _error(id, -32603, 'Internal error');
    } finally {
      _pendingRequests--;
    }
  }

  /// Tells a started app that part of its host context changed.
  void hostContextChanged(Map<String, dynamic> changes) {
    if (!_initialized || _closed || changes.isEmpty) return;
    _notify('ui/notifications/host-context-changed', changes);
  }

  /// Tells a started app it is being removed, then closes the host at once.
  ///
  /// The app's answer is not waited for: its web view goes with its widget,
  /// whose removal cannot wait, so the app has only until then.
  void teardown({String reason = 'The app was closed.'}) {
    if (_closed) return;
    if (_initialized) {
      _send({
        'jsonrpc': '2.0',
        'id': 'conduit-${_nextRequestId++}',
        'method': 'ui/resource-teardown',
        'params': {'reason': reason},
      });
    }
    close();
  }

  /// Stops answering the app.
  void close() => _closed = true;

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case 'ui/initialize':
        // A page that started over is sent its tool input and result again.
        _initialized = false;
        return {
          'protocolVersion': kMcpAppsProtocolVersion,
          'hostInfo': {'name': hostName, 'version': hostVersion},
          'hostCapabilities': {
            'openLinks': <String, dynamic>{},
            'serverTools': <String, dynamic>{},
            'serverResources': <String, dynamic>{},
            'logging': <String, dynamic>{},
            'sandbox': {'csp': resource.declaredCsp},
          },
          'hostContext': {
            ...hostContext(),
            'toolInfo': {'tool': resource.tool},
          },
        };
      case 'ping':
        return const <String, dynamic>{};
      case 'tools/call':
        final name = params['name'];
        final rawArguments = params['arguments'] ?? const <String, dynamic>{};
        if (name is! String || name.isEmpty || rawArguments is! Map) {
          throw const _McpAppRequestError(-32602, 'Invalid tool call');
        }
        final arguments = {
          for (final entry in rawArguments.entries)
            entry.key.toString(): entry.value,
        };
        if (!await _askUser(() => confirmToolCall(name, arguments))) {
          throw const _McpAppRequestError(-32000, 'Tool call cancelled');
        }
        if (_closed) throw const _McpAppRequestError(-32000, 'App closed');
        return runRequest('tools/call', {'name': name, 'arguments': arguments});
      case 'resources/read':
        final uri = params['uri'];
        if (uri is! String || uri.isEmpty) {
          throw const _McpAppRequestError(-32602, 'Invalid resource URI');
        }
        return runRequest('resources/read', {'uri': uri});
      case 'resources/list':
        final cursor = params['cursor'];
        if (cursor != null && cursor is! String) {
          throw const _McpAppRequestError(-32602, 'Invalid resource cursor');
        }
        return runRequest('resources/list', {'cursor': ?cursor});
      case 'ui/open-link':
        final url = Uri.tryParse('${params['url'] ?? ''}');
        if (url == null ||
            (url.scheme != 'http' && url.scheme != 'https') ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty) {
          throw const _McpAppRequestError(-32000, 'Invalid URL');
        }
        if (!await _askUser(() => openLink(url))) {
          throw const _McpAppRequestError(-32000, 'Link opening denied');
        }
        return const <String, dynamic>{};
      case 'ui/request-display-mode':
        // A chat shows its apps inline only, as the web client does.
        return const {'mode': 'inline'};
      default:
        // Includes ui/message and ui/update-model-context, which the web
        // client does not offer either.
        throw const _McpAppRequestError(-32601, 'Method not found');
    }
  }

  /// Runs [ask] unless the user is already being asked something for the
  /// app, which counts as a no.
  Future<bool> _askUser(Future<bool> Function() ask) async {
    if (_askingUser) return false;
    _askingUser = true;
    try {
      return await ask();
    } finally {
      _askingUser = false;
    }
  }

  void _notification(String method, Map<String, dynamic> params) {
    switch (method) {
      case 'ui/notifications/initialized':
        if (_initialized) return;
        _initialized = true;
        _notify('ui/notifications/tool-input', {'arguments': app.arguments});
        _notify('ui/notifications/tool-result', app.result);
        onInitialized?.call();
      case 'ui/notifications/size-changed':
        final height = params['height'];
        if (height is num && height.isFinite && height > 0) {
          onSizeChanged?.call(height.toDouble());
        }
    }
  }

  void _notify(String method, Map<String, dynamic> params) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  void _result(Object id, Map<String, dynamic> result) =>
      _send({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _error(Object id, int code, String message) => _send({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });

  void _send(Map<String, dynamic> message) {
    if (_closed) return;
    send(jsonEncode(message));
  }
}

final class _McpAppRequestError implements Exception {
  const _McpAppRequestError(this.code, this.message);

  final int code;
  final String message;
}
