import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../models/direct_completion.dart';
import '../models/direct_mcp_server.dart';
import 'ollama_cloud_tools.dart';

const int kDirectMcpMaxServers = 8;
const int kDirectMcpMaxTools = 128;
const int kDirectMcpMaxListPages = 32;
const int kDirectMcpMaxInventoryBytes = 512 * 1024;
const int kDirectMcpMaxDescriptionCharacters = 4096;
const int kDirectMcpMaxInputSchemaBytes = 64 * 1024;
const int kDirectMcpMaxDefinitionsBytes = 512 * 1024;
const int kDirectMcpMaxArgumentsBytes = 64 * 1024;

final class DirectMcpToolDefinition {
  DirectMcpToolDefinition({
    required this.serverId,
    required this.serverName,
    required this.remoteName,
    required this.modelName,
    required this.displayName,
    required this.description,
    required Map<String, dynamic> inputSchema,
  }) : inputSchema = Map.unmodifiable(inputSchema);

  final String serverId;
  final String serverName;
  final String remoteName;
  final String modelName;
  final String displayName;
  final String description;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toFunctionJson() => {
    'type': 'function',
    'function': {
      'name': modelName,
      if (description.isNotEmpty) 'description': description,
      'parameters': inputSchema,
    },
  };
}

final class DirectMcpToolCallResult {
  const DirectMcpToolCallResult({required this.text, this.isError = false});

  final String text;
  final bool isError;
}

typedef DirectMcpAuthorizationResolver = Future<String?> Function(
  DirectMcpServer server, {
  bool forceRefresh,
});

/// One Streamable HTTP MCP connection owned by one Direct run.
final class DirectMcpClient {
  DirectMcpClient({
    required this.endpoint,
    Map<String, String> headers = const {},
  }) : _headers = Map.unmodifiable(headers);

  final Uri endpoint;
  final Map<String, String> _headers;
  mcp.McpClient? _client;

  bool get isConnected => _client != null;

  Future<void> connect() async {
    if (_client != null) return;
    if (!endpoint.isAbsolute ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty) {
      throw const FormatException(
        'MCP endpoint must be an absolute HTTP or HTTPS URL.',
      );
    }

    final client = mcp.McpClient(
      const mcp.Implementation(name: 'conduit', version: '1.0.0'),
    );
    // ponytail: mcp_dart 2.4.1 owns its private HTTP client and redirect
    // behavior; inject Conduit's client or SDK redirect controls when exposed.
    final transport = mcp.StreamableHttpClientTransport(
      endpoint,
      opts: mcp.StreamableHttpClientTransportOptions(
        requestInit: {'headers': _headers},
      ),
    );
    try {
      await client.connect(transport);
      _client = client;
    } catch (_) {
      try {
        await client.close();
      } catch (_) {}
      rethrow;
    }
  }

  Future<List<mcp.Tool>> listTools() async {
    final client = _requireClient();
    final tools = <mcp.Tool>[];
    final seenCursors = <String>{};
    String? cursor;
    var pageCount = 0;
    var inventoryBytes = 0;
    do {
      if (pageCount >= kDirectMcpMaxListPages) {
        throw const DirectProviderException(
          'The MCP tool inventory has too many pages.',
        );
      }
      pageCount++;
      final result = await client.listTools(
        params: cursor == null ? null : mcp.ListToolsRequest(cursor: cursor),
      );
      if (tools.length + result.tools.length > kDirectMcpMaxTools) {
        throw const DirectProviderException(
          'The MCP server exposes more than 128 tools.',
        );
      }
      for (final tool in result.tools) {
        inventoryBytes += utf8.encode(jsonEncode(tool.toJson())).length;
        if (inventoryBytes > kDirectMcpMaxInventoryBytes) {
          throw const DirectProviderException(
            'The MCP tool inventory is too large.',
          );
        }
      }
      tools.addAll(result.tools);
      final nextCursor = result.nextCursor;
      if (nextCursor != null && !seenCursors.add(nextCursor)) {
        throw const DirectProviderException(
          'The MCP tool inventory repeated a pagination cursor.',
        );
      }
      cursor = nextCursor;
    } while (cursor != null);
    return List.unmodifiable(tools);
  }

  Future<mcp.CallToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) => _requireClient().callTool(
    mcp.CallToolRequest(name: name, arguments: arguments),
  );

  Future<void> close() async {
    final client = _client;
    _client = null;
    await client?.close();
  }

  mcp.McpClient _requireClient() {
    final client = _client;
    if (client == null) throw StateError('MCP client is not connected.');
    return client;
  }
}

/// Per-run MCP inventory and execution boundary.
final class DirectMcpToolSession {
  DirectMcpToolSession._(
    this._clients,
    this.definitions,
    this._targets,
    this._servers,
    this._authorizationResolver,
  );

  final Map<String, DirectMcpClient> _clients;
  final List<DirectMcpToolDefinition> definitions;
  final Map<String, ({String serverId, String remoteName})> _targets;
  final Map<String, DirectMcpServer> _servers;
  final DirectMcpAuthorizationResolver? _authorizationResolver;
  bool _closed = false;

  static Future<DirectMcpToolSession> open(
    Iterable<DirectMcpServer> selectedServers, {
    DirectMcpAuthorizationResolver? authorizationResolver,
  }) async {
    final servers = List<DirectMcpServer>.unmodifiable(selectedServers);
    if (servers.isEmpty) {
      throw const DirectProviderException('No MCP servers were selected.');
    }
    if (servers.length > kDirectMcpMaxServers) {
      throw const DirectProviderException(
        'At most 8 MCP servers may be selected.',
      );
    }

    final clients = <String, DirectMcpClient>{};
    final definitions = <DirectMcpToolDefinition>[];
    final targets = <String, ({String serverId, String remoteName})>{};
    var definitionsBytes = 0;
    try {
      for (final server in servers) {
        server.validate();
        if (!server.enabled) {
          throw DirectProviderException(
            'MCP server "${_safeName(server.name)}" is disabled.',
          );
        }
        if (clients.containsKey(server.id)) {
          throw const DirectProviderException(
            'Selected MCP server ids must be unique.',
          );
        }
        ({DirectMcpClient client, List<mcp.Tool> tools}) connected;
        try {
          connected = await _connectAndList(server, authorizationResolver);
        } catch (error) {
          if (!_isUnauthorizedError(error) ||
              server.authMode != DirectMcpAuthMode.oauth ||
              authorizationResolver == null) {
            rethrow;
          }
          connected = await _connectAndList(
            server,
            authorizationResolver,
            forceRefresh: true,
          );
        }
        final client = connected.client;
        final tools = connected.tools;
        clients[server.id] = client;
        for (var index = 0; index < tools.length; index++) {
          if (definitions.length >= kDirectMcpMaxTools) {
            throw const DirectProviderException(
              'Selected MCP servers expose more than 128 tools.',
            );
          }
          final tool = tools[index];
          final schema = Map<String, dynamic>.from(tool.inputSchema.toJson());
          final schemaBytes = utf8.encode(jsonEncode(schema)).length;
          if (schemaBytes > kDirectMcpMaxInputSchemaBytes) {
            throw DirectProviderException(
              'An MCP tool from "${_safeName(server.name)}" has an input schema that is too large.',
            );
          }
          var modelName = _baseModelName(server.id, tool.name);
          if (targets.containsKey(modelName)) {
            modelName = _collisionModelName(
              modelName,
              '${server.id}\u0000${tool.name}\u0000$index',
            );
          }
          if (targets.containsKey(modelName)) {
            throw const DirectProviderException(
              'MCP tool names could not be made unique.',
            );
          }
          final description = _truncate(
            tool.description ?? '',
            kDirectMcpMaxDescriptionCharacters,
          );
          final definition = DirectMcpToolDefinition(
            serverId: server.id,
            serverName: server.name,
            remoteName: tool.name,
            modelName: modelName,
            displayName: tool.title?.trim().isNotEmpty == true
                ? tool.title!.trim()
                : tool.name,
            description: description,
            inputSchema: schema,
          );
          definitionsBytes += utf8
              .encode(jsonEncode(definition.toFunctionJson()))
              .length;
          if (definitionsBytes > kDirectMcpMaxDefinitionsBytes) {
            throw const DirectProviderException(
              'Selected MCP tool definitions are too large.',
            );
          }
          definitions.add(definition);
          targets[modelName] = (serverId: server.id, remoteName: tool.name);
        }
      }
      return DirectMcpToolSession._(
        Map.unmodifiable(clients),
        List.unmodifiable(definitions),
        Map.unmodifiable(targets),
        Map.unmodifiable({for (final server in servers) server.id: server}),
        authorizationResolver,
      );
    } catch (error) {
      await _closeClients(clients.values, suppressErrors: true);
      if (error is DirectProviderException) rethrow;
      throw const DirectProviderException(
        'A selected MCP server could not be reached.',
      );
    }
  }

  bool containsTool(String modelName) => _targets.containsKey(modelName);

  DirectMcpToolDefinition definition(String modelName) =>
      definitions.firstWhere(
        (definition) => definition.modelName == modelName,
        orElse: () => throw const DirectProviderException(
          'The model requested an unavailable MCP tool.',
        ),
      );

  Future<DirectMcpToolCallResult> execute(
    String modelName,
    Map<String, dynamic> arguments,
  ) async {
    if (_closed) {
      throw const DirectProviderException('The MCP tool session is closed.');
    }
    final target = _targets[modelName];
    if (target == null) {
      throw const DirectProviderException(
        'The model requested an unavailable MCP tool.',
      );
    }
    final encodedArguments = jsonEncode(arguments);
    if (utf8.encode(encodedArguments).length > kDirectMcpMaxArgumentsBytes) {
      throw const DirectProviderException('MCP tool arguments are too large.');
    }
    try {
      final result = await _clients[target.serverId]!.callTool(
        target.remoteName,
        arguments,
      );
      return DirectMcpToolCallResult(
        text: _normalizeResult(result),
        isError: result.isError,
      );
    } catch (error) {
      if (!_isUnauthorizedError(error)) {
        if (error is DirectProviderException) rethrow;
        throw const DirectProviderException('The MCP tool call failed.');
      }
      final server = _servers[target.serverId]!;
      final resolver = _authorizationResolver;
      if (server.authMode == DirectMcpAuthMode.oauth && resolver != null) {
        try {
          await resolver(server, forceRefresh: true);
        } catch (_) {
          // The original tool call remains the public outcome.
        }
      }
      throw const DirectProviderException(
        'MCP authorization expired after a tool call. Retry the model turn.',
      );
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _closeClients(_clients.values);
  }
}

Future<DirectMcpClient> _connectAuthorizedClient(
  DirectMcpServer server,
  DirectMcpAuthorizationResolver? resolver, {
  bool forceRefresh = false,
}) async {
  final headers = Map<String, String>.from(server.customHeaders);
  if (server.authMode == DirectMcpAuthMode.bearer) {
    headers['Authorization'] = 'Bearer ${server.bearerToken}';
  } else if (server.authMode == DirectMcpAuthMode.oauth) {
    if (resolver == null) {
      throw const DirectProviderException(
        'MCP OAuth credentials are unavailable.',
      );
    }
    final token = await resolver(server, forceRefresh: forceRefresh);
    if (token == null || token.isEmpty) {
      throw const DirectProviderException(
        'MCP OAuth credentials are unavailable.',
      );
    }
    headers['Authorization'] = 'Bearer $token';
  }
  final client = DirectMcpClient(
    endpoint: server.endpointUri,
    headers: headers,
  );
  try {
    await client.connect();
    return client;
  } catch (_) {
    await client.close();
    rethrow;
  }
}

Future<({DirectMcpClient client, List<mcp.Tool> tools})> _connectAndList(
  DirectMcpServer server,
  DirectMcpAuthorizationResolver? resolver, {
  bool forceRefresh = false,
}) async {
  final client = await _connectAuthorizedClient(
    server,
    resolver,
    forceRefresh: forceRefresh,
  );
  try {
    return (client: client, tools: await client.listTools());
  } catch (_) {
    await client.close();
    rethrow;
  }
}

Future<void> _closeClients(
  Iterable<DirectMcpClient> clients, {
  bool suppressErrors = false,
}) async {
  Object? firstError;
  StackTrace? firstStack;
  for (final client in clients) {
    try {
      await client.close();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
  }
  if (!suppressErrors && firstError != null) {
    Error.throwWithStackTrace(firstError, firstStack!);
  }
}

String _normalizeResult(mcp.CallToolResult result) {
  final parts = <String>[];
  for (final content in result.content) {
    parts.add(switch (content) {
      mcp.TextContent() => content.text,
      mcp.ImageContent() => '[image content omitted: ${content.mimeType}]',
      mcp.AudioContent() => '[audio content omitted: ${content.mimeType}]',
      mcp.EmbeddedResource() => '[embedded resource content omitted]',
      mcp.ResourceLink() => '[resource link omitted: ${content.name}]',
      _ => '[unsupported MCP content omitted]',
    });
  }
  if (result.hasStructuredContent) {
    parts.add(jsonEncode(result.structuredContentJson!.toJson()));
  }
  return _truncate(
    parts.where((part) => part.isNotEmpty).join('\n'),
    kOllamaCloudMaxToolResultCharacters,
  );
}

String _baseModelName(String serverId, String remoteName) {
  final serverDigest = sha256.convert(utf8.encode(serverId)).toString();
  var safeRemote = remoteName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  if (safeRemote.isEmpty) safeRemote = 'tool';
  const prefixLength = 13; // mcp_ + 8 hex + _
  final remaining = 64 - prefixLength;
  if (safeRemote.length > remaining) {
    safeRemote = safeRemote.substring(0, remaining);
  }
  return 'mcp_${serverDigest.substring(0, 8)}_$safeRemote';
}

String _collisionModelName(String base, String identity) {
  final suffix = sha256
      .convert(utf8.encode(identity))
      .toString()
      .substring(0, 8);
  final prefixLength = 64 - suffix.length - 1;
  final end = base.length < prefixLength ? base.length : prefixLength;
  return '${base.substring(0, end)}_$suffix';
}

String _truncate(String value, int maxCharacters) {
  if (value.length <= maxCharacters) return value;
  const marker = '\n[truncated]';
  return '${value.substring(0, maxCharacters - marker.length)}$marker';
}

String _safeName(String value) {
  final safe = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
  return _truncate(safe, 128);
}

bool _isUnauthorizedError(Object error) =>
    error is mcp.UnauthorizedError ||
    (error is mcp.McpError && error.message.contains('HTTP 401'));
