import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../models/direct_completion.dart';
import '../models/direct_mcp_content.dart';
import '../models/direct_mcp_server.dart';
import 'direct_mcp_apps_protocol.dart';
import 'ollama_cloud_tools.dart';

const int kDirectMcpMaxTools = 128;
const int kDirectMcpMaxListPages = 32;
const int kDirectMcpMaxInventoryBytes = 512 * 1024;
const int kDirectMcpMaxDescriptionCharacters = 4096;
const int kDirectMcpMaxInputSchemaBytes = 64 * 1024;
const int kDirectMcpMaxDefinitionsBytes = 512 * 1024;
const int kDirectMcpMaxArgumentsBytes = 64 * 1024;
const int kDirectMcpApprovalFingerprintMaxDepth = 32;
const int kDirectMcpApprovalFingerprintMaxNodes = 8192;
const int kDirectMcpMaxContentListPages = 10;
const int kDirectMcpMaxPrompts = 512;
const int kDirectMcpMaxResources = 512;
const int kDirectMcpMaxContentNameCharacters = 4096;
const int kDirectMcpMaxPromptArguments = 32;
const int kDirectMcpMaxPromptArgumentNameCharacters = 128;
const int kDirectMcpMaxPromptArgumentValueBytes = 16 * 1024;
const int kDirectMcpMaxContentItemBytes = 128 * 1024;
const int kDirectMcpMaxInsertionBytes = 256 * 1024;
const int kDirectMcpMaxContentParts = 512;

String directMcpApprovalFingerprint({
  required String serverId,
  required String serverEndpoint,
  required String remoteToolName,
  required Map<String, dynamic> inputSchema,
}) {
  final canonical = _CanonicalJsonEncoder().encode([
    'direct-mcp-approval-v1',
    serverId,
    serverEndpoint,
    remoteToolName,
    inputSchema,
  ]);
  return sha256.convert(utf8.encode(canonical)).toString();
}

final class DirectMcpToolDefinition {
  DirectMcpToolDefinition({
    required this.serverId,
    required this.serverName,
    required this.remoteName,
    required this.modelName,
    required this.displayName,
    required this.description,
    required this.approvalFingerprint,
    required Map<String, dynamic> inputSchema,
  }) : inputSchema = Map.unmodifiable(inputSchema);

  final String serverId;
  final String serverName;
  final String remoteName;
  final String modelName;
  final String displayName;
  final String description;
  final String approvalFingerprint;
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
    this.allowInsecureCredentials = false,
  }) : _headers = Map.unmodifiable(headers);

  final Uri endpoint;
  final Map<String, String> _headers;
  final bool allowInsecureCredentials;
  mcp.McpClient? _client;

  bool get isConnected => _client != null;

  bool get supportsPrompts => _client?.getServerCapabilities()?.prompts != null;

  bool get supportsResources =>
      _client?.getServerCapabilities()?.resources != null;

  Future<void> connect() async {
    if (_client != null) return;
    if (!endpoint.isAbsolute ||
        !const {'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty) {
      throw const FormatException(
        'MCP endpoint must be an absolute HTTP or HTTPS URL.',
      );
    }
    if (_headers.isNotEmpty &&
        endpoint.scheme == 'http' &&
        !isDirectLoopbackHost(endpoint.host) &&
        !allowInsecureCredentials) {
      throw const FormatException(
        'Confirm sending MCP credentials over unencrypted HTTP.',
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

  Future<List<mcp.Prompt>> listPrompts({
    mcp.AbortSignal? signal,
  }) => _listBounded<mcp.Prompt>(
    maxPages: kDirectMcpMaxContentListPages,
    maxItems: kDirectMcpMaxPrompts,
    tooManyPages: 'The MCP prompt inventory has too many pages.',
    tooManyItems: 'The MCP server exposes more than 512 prompts.',
    tooLarge: 'The MCP prompt inventory is too large.',
    repeatedCursor: 'The MCP prompt inventory repeated a pagination cursor.',
    loadPage: (cursor) async {
      final result = await _requireClient().listPrompts(
        params: cursor == null ? null : mcp.ListPromptsRequest(cursor: cursor),
        options: mcp.RequestOptions(signal: signal),
      );
      return (items: result.prompts, nextCursor: result.nextCursor);
    },
    toJson: (prompt) => prompt.toJson(),
  );

  Future<mcp.GetPromptResult> getPrompt(
    String name,
    Map<String, String> arguments, {
    mcp.AbortSignal? signal,
  }) => _requireClient().getPrompt(
    mcp.GetPromptRequest(name: name, arguments: arguments),
    mcp.RequestOptions(signal: signal),
  );

  Future<List<mcp.Resource>> listResources({mcp.AbortSignal? signal}) =>
      _listBounded<mcp.Resource>(
        maxPages: kDirectMcpMaxContentListPages,
        maxItems: kDirectMcpMaxResources,
        tooManyPages: 'The MCP resource inventory has too many pages.',
        tooManyItems: 'The MCP server exposes more than 512 resources.',
        tooLarge: 'The MCP resource inventory is too large.',
        repeatedCursor:
            'The MCP resource inventory repeated a pagination cursor.',
        loadPage: (cursor) async {
          final result = await _requireClient().listResources(
            params: cursor == null
                ? null
                : mcp.ListResourcesRequest(cursor: cursor),
            options: mcp.RequestOptions(signal: signal),
          );
          return (items: result.resources, nextCursor: result.nextCursor);
        },
        toJson: (resource) => resource.toJson(),
      );

  Future<mcp.ReadResourceResult> readResource(
    String uri, {
    mcp.AbortSignal? signal,
  }) => _requireClient().readResource(
    mcp.ReadResourceRequest(uri: uri),
    mcp.RequestOptions(signal: signal),
  );

  Future<List<T>> _listBounded<T>({
    required int maxPages,
    required int maxItems,
    required String tooManyPages,
    required String tooManyItems,
    required String tooLarge,
    required String repeatedCursor,
    required Future<({List<T> items, String? nextCursor})> Function(
      String? cursor,
    )
    loadPage,
    required Map<String, dynamic> Function(T item) toJson,
  }) async {
    final items = <T>[];
    final cursors = <String>{};
    String? cursor;
    var pages = 0;
    var bytes = 0;
    do {
      if (pages++ >= maxPages) throw DirectProviderException(tooManyPages);
      final page = await loadPage(cursor);
      if (items.length + page.items.length > maxItems) {
        throw DirectProviderException(tooManyItems);
      }
      for (final item in page.items) {
        try {
          bytes += utf8
              .encode(_CanonicalJsonEncoder().encode(toJson(item)))
              .length;
        } on FormatException {
          throw const DirectProviderException(
            'The MCP content inventory is too complex.',
          );
        }
        if (bytes > kDirectMcpMaxInventoryBytes) {
          throw DirectProviderException(tooLarge);
        }
      }
      items.addAll(page.items);
      cursor = page.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        throw DirectProviderException(repeatedCursor);
      }
    } while (cursor != null);
    return List.unmodifiable(items);
  }

  Future<void> close() async {
    final client = _client;
    if (client == null) return;
    await client.close();
    if (identical(_client, client)) _client = null;
  }

  mcp.McpClient _requireClient() {
    final client = _client;
    if (client == null) throw StateError('MCP client is not connected.');
    return client;
  }
}

DirectMcpPromptSummary _normalizePrompt(mcp.Prompt prompt) {
  _requireBoundedLabel(prompt.name, 'An MCP prompt name is invalid.');
  final arguments = prompt.arguments ?? const <mcp.PromptArgument>[];
  if (arguments.length > kDirectMcpMaxPromptArguments) {
    throw const DirectProviderException(
      'An MCP prompt declares more than 32 arguments.',
    );
  }
  final seen = <String>{};
  final normalizedArguments = <DirectMcpPromptArgument>[];
  for (final argument in arguments) {
    if (argument.name.isEmpty ||
        argument.name.length > kDirectMcpMaxPromptArgumentNameCharacters ||
        !seen.add(argument.name)) {
      throw const DirectProviderException(
        'An MCP prompt argument name is invalid.',
      );
    }
    normalizedArguments.add(
      DirectMcpPromptArgument(
        name: argument.name,
        label: _boundedOptionalLabel(argument.title) ?? argument.name,
        description: _boundedDescription(argument.description),
        required: argument.required ?? false,
      ),
    );
  }
  return DirectMcpPromptSummary(
    name: prompt.name,
    displayName: _boundedOptionalLabel(prompt.title) ?? prompt.name,
    description: _boundedDescription(prompt.description),
    arguments: normalizedArguments,
    inventoryIdentity: _contentIdentity(prompt.toJson()),
  );
}

DirectMcpResourceSummary _normalizeResource(mcp.Resource resource) {
  _requireBoundedLabel(resource.name, 'An MCP resource name is invalid.');
  if (resource.uri.isEmpty ||
      resource.uri.length > kDirectMcpMaxContentNameCharacters) {
    throw const DirectProviderException('An MCP resource URI is invalid.');
  }
  return DirectMcpResourceSummary(
    uri: resource.uri,
    displayName: _boundedOptionalLabel(resource.title) ?? resource.name,
    description: _boundedDescription(resource.description),
    mimeType: resource.mimeType,
    inventoryIdentity: _contentIdentity(resource.toJson()),
  );
}

void _validatePromptArguments(
  DirectMcpPromptSummary prompt,
  Map<String, String> values,
) {
  if (values.length > kDirectMcpMaxPromptArguments) {
    throw const DirectProviderException('Too many MCP prompt arguments.');
  }
  final definitions = {
    for (final argument in prompt.arguments) argument.name: argument,
  };
  if (values.keys.any((name) => !definitions.containsKey(name))) {
    throw const DirectProviderException(
      'The MCP prompt arguments no longer match this prompt.',
    );
  }
  for (final argument in prompt.arguments) {
    final value = values[argument.name];
    if (argument.required && (value == null || value.trim().isEmpty)) {
      throw DirectProviderException(
        'The required MCP prompt argument "${_safeName(argument.label)}" is empty.',
      );
    }
    if (value != null &&
        utf8.encode(value).length > kDirectMcpMaxPromptArgumentValueBytes) {
      throw const DirectProviderException(
        'An MCP prompt argument is larger than 16 KiB.',
      );
    }
  }
}

String _contentIdentity(Map<String, dynamic> value) {
  try {
    return _CanonicalJsonEncoder().encode(value);
  } on FormatException {
    throw const DirectProviderException('The MCP content is too complex.');
  }
}

void _requireBoundedLabel(String value, String message) {
  if (value.isEmpty || value.length > kDirectMcpMaxContentNameCharacters) {
    throw DirectProviderException(message);
  }
}

String? _boundedOptionalLabel(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  _requireBoundedLabel(value, 'An MCP content title is invalid.');
  return value;
}

String _boundedDescription(String? value) {
  if (value == null) return '';
  if (value.length > kDirectMcpMaxDescriptionCharacters) {
    throw const DirectProviderException(
      'An MCP content description is too large.',
    );
  }
  return value;
}

bool _isTextMimeType(String? mimeType) =>
    mimeType == null || mimeType.toLowerCase().startsWith('text/');

/// One authenticated MCP connection for explicit prompt/resource browsing.
final class DirectMcpContentSession {
  DirectMcpContentSession._(
    this.server,
    this._client,
    this._authorizationResolver,
  );

  final DirectMcpServer server;
  DirectMcpClient _client;
  final DirectMcpAuthorizationResolver? _authorizationResolver;
  bool _closed = false;

  static Future<DirectMcpContentSession> open(
    DirectMcpServer server, {
    DirectMcpAuthorizationResolver? authorizationResolver,
  }) async {
    server.validate();
    if (!server.enabled) {
      throw const DirectProviderException('The MCP server is disabled.');
    }
    try {
      final client = await _connectAuthorizedClient(
        server,
        authorizationResolver,
      );
      return DirectMcpContentSession._(server, client, authorizationResolver);
    } catch (error) {
      if (error is DirectProviderException) rethrow;
      if (!_isUnauthorizedError(error) ||
          server.authMode != DirectMcpAuthMode.oauth ||
          authorizationResolver == null) {
        throw const DirectProviderException(
          'The MCP content server could not be reached.',
        );
      }
      try {
        final client = await _connectAuthorizedClient(
          server,
          authorizationResolver,
          forceRefresh: true,
        );
        return DirectMcpContentSession._(server, client, authorizationResolver);
      } catch (refreshError) {
        if (refreshError is DirectProviderException) rethrow;
        throw const DirectProviderException(
          'The MCP content server could not be reached.',
        );
      }
    }
  }

  Future<DirectMcpContentInventory> loadInventory({mcp.AbortSignal? signal}) =>
      _guarded(() async {
        final prompts = _client.supportsPrompts
            ? await _client.listPrompts(signal: signal)
            : const <mcp.Prompt>[];
        signal?.throwIfAborted();
        final resources = _client.supportsResources
            ? await _client.listResources(signal: signal)
            : const <mcp.Resource>[];
        final normalizedPrompts = prompts.map(_normalizePrompt).toList();
        final normalizedResources = resources.map(_normalizeResource).toList();
        if (normalizedPrompts.map((prompt) => prompt.name).toSet().length !=
                normalizedPrompts.length ||
            normalizedResources
                    .map((resource) => resource.uri)
                    .toSet()
                    .length !=
                normalizedResources.length) {
          throw const DirectProviderException(
            'The MCP content inventory contains duplicate identities.',
          );
        }
        return DirectMcpContentInventory(
          serverId: server.id,
          serverName: server.name,
          prompts: normalizedPrompts,
          resources: normalizedResources,
        );
      });

  Future<DirectMcpPromptPreview> getPrompt(
    DirectMcpPromptSummary selected,
    Map<String, String> arguments, {
    mcp.AbortSignal? signal,
  }) => _guarded(() async {
    final fresh = (await _client.listPrompts(signal: signal))
        .map(_normalizePrompt)
        .where((prompt) => prompt.name == selected.name)
        .toList();
    if (fresh.length != 1 ||
        fresh.single.inventoryIdentity != selected.inventoryIdentity) {
      throw const DirectProviderException(
        'This MCP prompt changed. Refresh and try again.',
        reason: DirectProviderFailureReason.changed,
      );
    }
    _validatePromptArguments(fresh.single, arguments);
    signal?.throwIfAborted();
    final result = await _client.getPrompt(
      selected.name,
      arguments,
      signal: signal,
    );
    if (result.messages.length > kDirectMcpMaxContentParts) {
      throw const DirectProviderException(
        'The MCP prompt has too many messages.',
        reason: DirectProviderFailureReason.tooLarge,
      );
    }
    var totalBytes = 0;
    final messages = <DirectMcpPromptMessage>[];
    for (final message in result.messages) {
      final content = message.content;
      if (content is! mcp.TextContent) {
        throw const DirectProviderException(
          'This MCP prompt contains unsupported non-text content.',
          reason: DirectProviderFailureReason.unsupported,
        );
      }
      final bytes = utf8.encode(content.text).length;
      if (bytes > kDirectMcpMaxContentItemBytes) {
        throw const DirectProviderException(
          'An MCP prompt message is larger than 128 KiB.',
          reason: DirectProviderFailureReason.tooLarge,
        );
      }
      totalBytes += bytes;
      if (totalBytes > kDirectMcpMaxInsertionBytes) {
        throw const DirectProviderException(
          'The MCP prompt is larger than 256 KiB.',
          reason: DirectProviderFailureReason.tooLarge,
        );
      }
      messages.add(
        DirectMcpPromptMessage(role: message.role.name, text: content.text),
      );
    }
    return DirectMcpPromptPreview(messages: messages);
  });

  Future<DirectMcpResourcePreview> readResource(
    DirectMcpResourceSummary selected, {
    mcp.AbortSignal? signal,
  }) => _guarded(() async {
    final fresh = (await _client.listResources(signal: signal))
        .map(_normalizeResource)
        .where((resource) => resource.uri == selected.uri)
        .toList();
    if (fresh.length != 1 ||
        fresh.single.inventoryIdentity != selected.inventoryIdentity) {
      throw const DirectProviderException(
        'This MCP resource changed. Refresh and try again.',
        reason: DirectProviderFailureReason.changed,
      );
    }
    signal?.throwIfAborted();
    final result = await _client.readResource(selected.uri, signal: signal);
    if (result.contents.length > kDirectMcpMaxContentParts) {
      throw const DirectProviderException(
        'The MCP resource has too many items.',
        reason: DirectProviderFailureReason.tooLarge,
      );
    }
    final parts = <String>[];
    var totalBytes = 0;
    for (final content in result.contents) {
      if (content is! mcp.TextResourceContents ||
          content.uri != selected.uri ||
          !_isTextMimeType(content.mimeType ?? selected.mimeType)) {
        throw const DirectProviderException(
          'This MCP resource is not supported text content.',
          reason: DirectProviderFailureReason.unsupported,
        );
      }
      final bytes = utf8.encode(content.text).length;
      if (bytes > kDirectMcpMaxContentItemBytes) {
        throw const DirectProviderException(
          'An MCP resource item is larger than 128 KiB.',
          reason: DirectProviderFailureReason.tooLarge,
        );
      }
      totalBytes += bytes;
      if (totalBytes > kDirectMcpMaxInsertionBytes) {
        throw const DirectProviderException(
          'The MCP resource is larger than 256 KiB.',
          reason: DirectProviderFailureReason.tooLarge,
        );
      }
      parts.add(content.text);
    }
    return DirectMcpResourcePreview(text: parts.join('\n'));
  });

  Future<T> _guarded<T>(Future<T> Function() operation) async {
    if (_closed) {
      throw const DirectProviderException('The MCP content session is closed.');
    }
    try {
      return await operation();
    } catch (error) {
      if (error is mcp.AbortError || error is DirectProviderException) rethrow;
      if (_isUnauthorizedError(error) &&
          server.authMode == DirectMcpAuthMode.oauth &&
          _authorizationResolver != null) {
        try {
          await _client.close();
          final refreshed = await _connectAuthorizedClient(
            server,
            _authorizationResolver,
            forceRefresh: true,
          );
          if (_closed) {
            try {
              await refreshed.close();
            } catch (_) {}
            throw const DirectProviderException(
              'The MCP content session is closed.',
            );
          }
          _client = refreshed;
          return await operation();
        } catch (retryError) {
          if (retryError is mcp.AbortError ||
              retryError is DirectProviderException) {
            rethrow;
          }
        }
      }
      throw const DirectProviderException('The MCP content request failed.');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _client.close();
    } catch (_) {
      _closed = false;
      rethrow;
    }
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
        clients[server.id] = client;
        final List<mcp.Tool> tools;
        try {
          tools = directMcpToolsVisibleToModel(
            connected.tools,
            serverId: server.id,
          );
        } on DirectMcpAppsProtocolException {
          throw const DirectProviderException(
            'An MCP tool has invalid app metadata.',
          );
        }
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
            displayName: _truncateSingleLine(
              tool.title?.trim().isNotEmpty == true
                  ? tool.title!.trim()
                  : tool.name,
              kDirectMcpMaxRememberedDisplayNameCharacters,
            ),
            description: description,
            approvalFingerprint: directMcpApprovalFingerprint(
              serverId: server.id,
              serverEndpoint: server.endpoint.trim(),
              remoteToolName: tool.name,
              inputSchema: schema,
            ),
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
    allowInsecureCredentials: server.allowInsecureCredentials,
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
  const bufferLimit = kOllamaCloudMaxToolResultCharacters + 1;
  final output = StringBuffer();
  void append(String value) {
    if (value.isEmpty || output.length >= bufferLimit) {
      return;
    }
    if (output.isNotEmpty) output.write('\n');
    final remaining = bufferLimit - output.length;
    output.write(
      value.length <= remaining ? value : value.substring(0, remaining),
    );
  }

  for (final content in result.content) {
    append(switch (content) {
      mcp.TextContent() => content.text,
      mcp.ImageContent() => '[image content omitted: ${content.mimeType}]',
      mcp.AudioContent() => '[audio content omitted: ${content.mimeType}]',
      mcp.EmbeddedResource() => '[embedded resource content omitted]',
      mcp.ResourceLink() => '[resource link omitted: ${content.name}]',
      _ => '[unsupported MCP content omitted]',
    });
  }
  if (result.hasStructuredContent && output.length < bufferLimit) {
    final sink = _BoundedStringSink(
      bufferLimit - output.length - (output.isEmpty ? 0 : 1),
    );
    final encoder = json.encoder.startChunkedConversion(sink);
    encoder.add(result.structuredContentJson!.toJson());
    encoder.close();
    append(sink.value);
  }
  return _truncate(output.toString(), kOllamaCloudMaxToolResultCharacters);
}

final class _BoundedStringSink implements ChunkedConversionSink<String> {
  _BoundedStringSink(this.limit);

  final int limit;
  final StringBuffer _buffer = StringBuffer();
  String get value => _buffer.toString();

  @override
  void add(String chunk) {
    final remaining = limit - _buffer.length;
    if (remaining > 0) {
      _buffer.write(
        chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
      );
    }
  }

  @override
  void close() {}
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

String _truncateSingleLine(String value, int maxCharacters) {
  final safe = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
  if (safe.length <= maxCharacters) return safe;
  return '${safe.substring(0, maxCharacters - 1)}…';
}

String _safeName(String value) {
  final safe = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();
  return _truncate(safe, 128);
}

bool _isUnauthorizedError(Object error) =>
    error is mcp.UnauthorizedError ||
    (error is mcp.McpError && error.message.contains('HTTP 401'));

final class _CanonicalJsonEncoder {
  var _nodes = 0;

  String encode(Object? value) => jsonEncode(_normalize(value, 0));

  Object? _normalize(Object? value, int depth) {
    _nodes++;
    if (_nodes > kDirectMcpApprovalFingerprintMaxNodes ||
        depth > kDirectMcpApprovalFingerprintMaxDepth) {
      throw const FormatException(
        'The MCP tool schema is too complex to fingerprint.',
      );
    }
    if (value == null || value is bool || value is String || value is int) {
      return value;
    }
    if (value is double) {
      if (!value.isFinite) {
        throw const FormatException(
          'The MCP tool schema contains a non-finite number.',
        );
      }
      return value;
    }
    if (value is List) {
      return [for (final item in value) _normalize(item, depth + 1)];
    }
    if (value is Map) {
      if (value.keys.any((key) => key is! String)) {
        throw const FormatException(
          'The MCP tool schema contains a non-string object key.',
        );
      }
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _normalize(value[key], depth + 1)};
    }
    throw const FormatException(
      'The MCP tool schema contains a non-JSON value.',
    );
  }
}
