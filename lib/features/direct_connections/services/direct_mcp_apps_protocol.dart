import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../models/direct_mcp_app.dart';

const String kDirectMcpAppsProtocolVersion = '2026-01-26';
const int kDirectMcpAppsMaxMessageBytes = 256 * 1024;
const int kDirectMcpAppsMaxJsonDepth = 32;
const int kDirectMcpAppsMaxJsonNodes = 8192;
const int kDirectMcpAppsMaxPendingRequests = 16;
const int kDirectMcpAppsMaxMessagesPerSecond = 20;
const int kDirectMcpAppsRateBurst = 4;
const int kDirectMcpAppsMaxIdCharacters = 128;
const int kDirectMcpAppsMaxMethodCharacters = 128;
const int kDirectMcpAppsMaxToolNameCharacters = 256;
const int kDirectMcpAppsMaxResourceUriCharacters = 4096;
const int kDirectMcpAppsMaxCspDomains = 32;
const int kDirectMcpAppsMaxCspDomainCharacters = 2048;

final class DirectMcpAppsProtocolException implements Exception {
  const DirectMcpAppsProtocolException(this.message);

  final String message;

  @override
  String toString() => 'DirectMcpAppsProtocolException: $message';
}

/// Strict per-view boundary for Conduit's stable, capability-off MCP Apps spike.
final class DirectMcpAppsProtocol {
  DirectMcpAppsProtocol({
    required this.serverId,
    required Iterable<DirectMcpAppToolPolicy> tools,
    int Function()? nowMicros,
  }) : _tools = Map.unmodifiable({
         for (final tool in tools)
           if (tool.serverId == serverId) tool.toolName: tool,
       }),
       _nowMicros = nowMicros ?? _systemMicros,
       _lastRefillMicros = (nowMicros ?? _systemMicros)(),
       _tokens = (kDirectMcpAppsMaxMessagesPerSecond + kDirectMcpAppsRateBurst)
           .toDouble();

  final String serverId;
  final Map<String, DirectMcpAppToolPolicy> _tools;
  final int Function() _nowMicros;
  final Set<Object> _pendingRequestIds = <Object>{};
  int _lastRefillMicros;
  double _tokens;
  bool _closed = false;

  DirectMcpAppInboundMessage decodeInbound(String payload) {
    _assertOpen();
    _takeRateToken();
    if (utf8.encode(payload).length > kDirectMcpAppsMaxMessageBytes) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App message is too large.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
      _validateJson(decoded);
    } on DirectMcpAppsProtocolException {
      rethrow;
    } catch (_) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App message is not valid JSON.',
      );
    }
    if (decoded is! Map<String, dynamic> || decoded['jsonrpc'] != '2.0') {
      throw const DirectMcpAppsProtocolException(
        'The MCP App message is not JSON-RPC 2.0.',
      );
    }
    final method = decoded['method'];
    if (method is! String ||
        method.isEmpty ||
        method.length > kDirectMcpAppsMaxMethodCharacters) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App method is invalid.',
      );
    }
    final params = switch (decoded['params']) {
      null => const <String, dynamic>{},
      final Map<String, dynamic> value => value,
      _ => throw const DirectMcpAppsProtocolException(
        'The MCP App parameters are invalid.',
      ),
    };
    final id = decoded['id'];

    return switch (method) {
      'ui/initialize' => _decodeInitialize(id, params),
      'ui/notifications/initialized' => _decodeInitialized(id),
      'ping' => DirectMcpAppPingRequest(_reserveRequestId(id)),
      'tools/call' => _decodeToolCall(id, params),
      _ => throw const DirectMcpAppsProtocolException(
        'The MCP App method is not supported.',
      ),
    };
  }

  void completeRequest(Object id) => _pendingRequestIds.remove(id);

  void close() {
    _closed = true;
    _pendingRequestIds.clear();
  }

  Map<String, dynamic> initializeResult(Object id) {
    _assertOpen();
    return _boundedHostMessage({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'protocolVersion': kDirectMcpAppsProtocolVersion,
        'hostCapabilities': {
          'serverTools': {'listChanged': false},
          'sandbox': {
            'permissions': <String, dynamic>{},
            'csp': {
              'connectDomains': <String>[],
              'resourceDomains': <String>[],
              'frameDomains': <String>[],
              'baseUriDomains': <String>[],
            },
          },
        },
        'hostInfo': {'name': 'conduit', 'version': '1.0.0'},
        'hostContext': {
          'displayMode': 'inline',
          'availableDisplayModes': ['inline'],
          'platform': 'mobile',
        },
      },
    });
  }

  Map<String, dynamic> toolInputNotification(Map<String, dynamic> arguments) {
    _assertOpen();
    return _boundedHostMessage({
      'jsonrpc': '2.0',
      'method': 'ui/notifications/tool-input',
      'params': {'arguments': arguments},
    });
  }

  Map<String, dynamic> toolResultNotification(Map<String, dynamic> result) {
    _assertOpen();
    return _boundedHostMessage({
      'jsonrpc': '2.0',
      'method': 'ui/notifications/tool-result',
      'params': result,
    });
  }

  void _assertOpen() {
    if (_closed) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App session is closed.',
      );
    }
  }

  DirectMcpAppInitializeRequest _decodeInitialize(
    Object? id,
    Map<String, dynamic> params,
  ) {
    if (params['protocolVersion'] != kDirectMcpAppsProtocolVersion) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App protocol version is not supported.',
      );
    }
    final capabilities = params['appCapabilities'];
    if (capabilities is! Map<String, dynamic>) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App capabilities are invalid.',
      );
    }
    return DirectMcpAppInitializeRequest(
      id: _reserveRequestId(id),
      appCapabilities: Map.unmodifiable(capabilities),
    );
  }

  DirectMcpAppInitializedNotification _decodeInitialized(Object? id) {
    if (id != null) {
      throw const DirectMcpAppsProtocolException(
        'The initialized message must be a notification.',
      );
    }
    return const DirectMcpAppInitializedNotification();
  }

  DirectMcpAppToolCallRequest _decodeToolCall(
    Object? id,
    Map<String, dynamic> params,
  ) {
    final name = params['name'];
    if (name is! String ||
        name.isEmpty ||
        name.length > kDirectMcpAppsMaxToolNameCharacters) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App tool name is invalid.',
      );
    }
    final policy = _tools[name];
    if (policy == null || policy.serverId != serverId || !policy.visibleToApp) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App tool target is not allowed.',
      );
    }
    if (params.containsKey('serverId') && params['serverId'] != serverId) {
      throw const DirectMcpAppsProtocolException(
        'Cross-server MCP App tool calls are not allowed.',
      );
    }
    final arguments = switch (params['arguments']) {
      null => const <String, dynamic>{},
      final Map<String, dynamic> value => value,
      _ => throw const DirectMcpAppsProtocolException(
        'The MCP App tool arguments are invalid.',
      ),
    };
    return DirectMcpAppToolCallRequest(
      id: _reserveRequestId(id),
      toolName: name,
      arguments: arguments,
    );
  }

  Object _reserveRequestId(Object? id) {
    if (id is String) {
      if (id.isEmpty || id.length > kDirectMcpAppsMaxIdCharacters) {
        throw const DirectMcpAppsProtocolException(
          'The MCP App request id is invalid.',
        );
      }
    } else if (id is! int) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App request id is invalid.',
      );
    }
    final validId = id!;
    if (_pendingRequestIds.length >= kDirectMcpAppsMaxPendingRequests) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App has too many pending requests.',
      );
    }
    if (!_pendingRequestIds.add(validId)) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App repeated a pending request id.',
      );
    }
    return validId;
  }

  Map<String, dynamic> _boundedHostMessage(Map<String, dynamic> message) {
    _validateJson(message);
    if (utf8.encode(jsonEncode(message)).length >
        kDirectMcpAppsMaxMessageBytes) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App host message is too large.',
      );
    }
    return message;
  }

  void _takeRateToken() {
    final now = _nowMicros();
    final elapsed = now - _lastRefillMicros;
    if (elapsed <= 0) {
      _lastRefillMicros = now;
    } else {
      _tokens += elapsed * kDirectMcpAppsMaxMessagesPerSecond / 1000000;
      final capacity =
          kDirectMcpAppsMaxMessagesPerSecond + kDirectMcpAppsRateBurst;
      if (_tokens > capacity) _tokens = capacity.toDouble();
      _lastRefillMicros = now;
    }
    if (_tokens < 1) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App message rate is too high.',
      );
    }
    _tokens--;
  }
}

DirectMcpAppToolPolicy directMcpAppToolPolicy(
  mcp.Tool tool, {
  required String serverId,
}) {
  final rawUi = tool.meta?['ui'];
  if (rawUi != null &&
      (rawUi is! Map || rawUi.keys.any((key) => key is! String))) {
    throw const DirectMcpAppsProtocolException(
      'The MCP App tool metadata is invalid.',
    );
  }
  final ui = rawUi == null
      ? const <String, dynamic>{}
      : Map<String, dynamic>.from(rawUi as Map);
  final rawVisibility = ui['visibility'];
  final visibility = rawVisibility == null
      ? const {'model', 'app'}
      : _strictStringSet(rawVisibility, 'tool visibility');
  if (visibility.any((value) => value != 'model' && value != 'app')) {
    throw const DirectMcpAppsProtocolException(
      'The MCP App tool visibility is invalid.',
    );
  }
  final resourceUri = ui['resourceUri'];
  if (resourceUri != null) {
    if (resourceUri is! String ||
        resourceUri.length > kDirectMcpAppsMaxResourceUriCharacters ||
        !_isUiUri(resourceUri)) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App resource URI is invalid.',
      );
    }
  }
  return DirectMcpAppToolPolicy(
    serverId: serverId,
    toolName: tool.name,
    visibleToModel: visibility.contains('model'),
    visibleToApp: visibility.contains('app'),
    resourceUri: resourceUri as String?,
  );
}

List<mcp.Tool> directMcpToolsVisibleToModel(
  Iterable<mcp.Tool> tools, {
  required String serverId,
}) => List.unmodifiable(
  tools.where(
    (tool) => directMcpAppToolPolicy(tool, serverId: serverId).visibleToModel,
  ),
);

DirectMcpAppResourcePolicy directMcpAppResourcePolicy(
  Map<String, dynamic>? meta,
) {
  final rawUi = meta?['ui'];
  if (rawUi != null &&
      (rawUi is! Map || rawUi.keys.any((key) => key is! String))) {
    throw const DirectMcpAppsProtocolException(
      'The MCP App resource metadata is invalid.',
    );
  }
  final ui = rawUi == null
      ? const <String, dynamic>{}
      : Map<String, dynamic>.from(rawUi as Map);
  if (ui['domain'] != null) {
    throw const DirectMcpAppsProtocolException(
      'Dedicated MCP App domains are not supported.',
    );
  }
  final rawCsp = ui['csp'];
  if (rawCsp != null &&
      (rawCsp is! Map || rawCsp.keys.any((key) => key is! String))) {
    throw const DirectMcpAppsProtocolException(
      'The MCP App CSP metadata is invalid.',
    );
  }
  final csp = rawCsp == null
      ? const <String, dynamic>{}
      : Map<String, dynamic>.from(rawCsp as Map);
  final rawPermissions = ui['permissions'];
  if (rawPermissions != null &&
      (rawPermissions is! Map ||
          rawPermissions.keys.any((key) => key is! String))) {
    throw const DirectMcpAppsProtocolException(
      'The MCP App permission metadata is invalid.',
    );
  }
  final permissions = rawPermissions == null
      ? const <String, dynamic>{}
      : Map<String, dynamic>.from(rawPermissions as Map);
  const permissionKeys = {
    'camera',
    'microphone',
    'geolocation',
    'clipboardWrite',
  };
  if (permissions.keys.any((key) => !permissionKeys.contains(key)) ||
      permissions.values.any((value) => value is! Map || value.isNotEmpty)) {
    throw const DirectMcpAppsProtocolException(
      'The MCP App permission metadata is invalid.',
    );
  }
  final prefersBorder = ui['prefersBorder'];
  if (prefersBorder != null && prefersBorder is! bool) {
    throw const DirectMcpAppsProtocolException(
      'The MCP App border preference is invalid.',
    );
  }
  return DirectMcpAppResourcePolicy(
    connectDomains: _cspDomains(csp['connectDomains'], allowWebSocket: true),
    resourceDomains: _cspDomains(csp['resourceDomains']),
    frameDomains: _cspDomains(csp['frameDomains']),
    baseUriDomains: _cspDomains(csp['baseUriDomains']),
    requestsCamera: permissions.containsKey('camera'),
    requestsMicrophone: permissions.containsKey('microphone'),
    requestsGeolocation: permissions.containsKey('geolocation'),
    requestsClipboardWrite: permissions.containsKey('clipboardWrite'),
    prefersBorder: prefersBorder as bool?,
  );
}

Set<String> _strictStringSet(Object raw, String field) {
  if (raw is! List || raw.any((value) => value is! String)) {
    throw DirectMcpAppsProtocolException('The MCP App $field is invalid.');
  }
  final values = raw.cast<String>();
  if (values.toSet().length != values.length) {
    throw DirectMcpAppsProtocolException('The MCP App $field is invalid.');
  }
  return values.toSet();
}

List<String> _cspDomains(Object? raw, {bool allowWebSocket = false}) {
  if (raw == null) return const [];
  final values = _strictStringSet(raw, 'CSP domain list');
  if (values.length > kDirectMcpAppsMaxCspDomains) {
    throw const DirectMcpAppsProtocolException(
      'The MCP App CSP domain list is too large.',
    );
  }
  for (final value in values) {
    final wildcard = value.contains('*');
    final allowedWildcard =
        value.startsWith('https://*.') ||
        allowWebSocket && value.startsWith('wss://*.');
    if (wildcard &&
        (!allowedWildcard || value.indexOf('*') != value.lastIndexOf('*'))) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App CSP contains an invalid origin.',
      );
    }
    final normalized = allowedWildcard
        ? value.replaceFirst('://*.', '://wildcard.')
        : value;
    final uri = Uri.tryParse(normalized);
    final schemes = allowWebSocket ? const {'https', 'wss'} : const {'https'};
    if (value.length > kDirectMcpAppsMaxCspDomainCharacters ||
        uri == null ||
        !schemes.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty && uri.path != '/' ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App CSP contains an invalid origin.',
      );
    }
  }
  return List.unmodifiable(values);
}

bool _isUiUri(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == mcp.mcpUiResourceUriScheme &&
      uri.host.isNotEmpty;
}

void _validateJson(Object? root) {
  var nodes = 0;
  void visit(Object? value, int depth) {
    if (++nodes > kDirectMcpAppsMaxJsonNodes ||
        depth > kDirectMcpAppsMaxJsonDepth) {
      throw const DirectMcpAppsProtocolException(
        'The MCP App message is too complex.',
      );
    }
    switch (value) {
      case null || bool() || String() || int():
        return;
      case double():
        if (!value.isFinite) {
          throw const DirectMcpAppsProtocolException(
            'The MCP App message contains an invalid number.',
          );
        }
      case List():
        for (final item in value) {
          visit(item, depth + 1);
        }
      case Map():
        if (value.keys.any((key) => key is! String)) {
          throw const DirectMcpAppsProtocolException(
            'The MCP App message contains an invalid object key.',
          );
        }
        for (final item in value.values) {
          visit(item, depth + 1);
        }
      default:
        throw const DirectMcpAppsProtocolException(
          'The MCP App message contains a non-JSON value.',
        );
    }
  }

  visit(root, 0);
}

final Stopwatch _protocolClock = Stopwatch()..start();

int _systemMicros() => _protocolClock.elapsedMicroseconds;
