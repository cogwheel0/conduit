part of 'chat_providers.dart';

// ========== Shared Streaming Utilities ==========

// ========== Tool Servers (OpenAPI) Helpers ==========

/// Reads each enabled server's OpenAPI document and builds the `tool_servers`
/// entries for a completion request.
///
/// A direct terminal ([terminal]) also carries its key and `is_terminal`: the
/// server calls the terminal itself and has no other source for that key.
///
/// Each entry that is resolved is also added to [admitted], exactly as it goes
/// into the request, so what may be called back is what was sent.
Future<List<Map<String, dynamic>>> _resolveToolServers(
  List rawServers,
  dynamic api, {
  bool terminal = false,
  List<PersonalToolAdmission>? admitted,
}) async {
  final List<Map<String, dynamic>> resolved = [];
  for (final s in rawServers) {
    try {
      if (s is! Map || !_isConfiguredServerEnabled(s)) continue;

      final url = (s['url'] ?? '').toString();

      // Read the OpenAPI document (JSON or YAML, inline or fetched) with the
      // connection's own credentials. The Open WebUI client is not used: its
      // interceptor drops credentials for other origins, which would leave
      // every key-protected personal server unreadable.
      final Map<String, dynamic> openapi;
      try {
        openapi = (await probePersonalToolServer(normalizeJsonLikeMap(s))).spec;
      } on PersonalConnectionProbeException {
        continue;
      }

      // Convert OpenAPI to tool specs
      final specs = _convertOpenApiToToolPayload(openapi);
      admitted?.add(
        PersonalToolAdmission.forRequestEntry(
          terminal
              ? PersonalConnectionKind.terminal
              : PersonalConnectionKind.toolServer,
          normalizeJsonLikeMap(s),
          specs,
        ),
      );
      resolved.add({
        'url': url,
        'openapi': openapi,
        'info': openapi['info'],
        'specs': specs,
        if (terminal) ...{
          'key': (s['key'] ?? '').toString(),
          'is_terminal': true,
        },
      });
    } catch (_) {
      continue;
    }
  }
  return resolved;
}

Map<String, dynamic>? _resolveRef(
  String ref,
  Map<String, dynamic>? components,
) {
  // e.g., #/components/schemas/MySchema
  if (!ref.startsWith('#/')) return null;
  final parts = ref.split('/');
  if (parts.length < 4) return null;
  final type = parts[2]; // schemas
  final name = parts[3];
  final section = components?[type];
  if (section is Map<String, dynamic>) {
    final schema = section[name];
    if (schema is Map<String, dynamic>) {
      return Map<String, dynamic>.from(schema);
    }
  }
  return null;
}

Map<String, dynamic> _resolveSchemaSimple(
  dynamic schema,
  Map<String, dynamic>? components,
) {
  if (schema is Map<String, dynamic>) {
    if (schema.containsKey(r'$ref')) {
      final ref = schema[r'$ref'] as String;
      final resolved = _resolveRef(ref, components);
      if (resolved != null) return _resolveSchemaSimple(resolved, components);
    }
    final type = schema['type'];
    final out = <String, dynamic>{};
    if (type is String) {
      out['type'] = type;
      if (schema['description'] != null) {
        out['description'] = schema['description'];
      }
      if (type == 'object') {
        out['properties'] = <String, dynamic>{};
        if (schema['required'] is List) {
          out['required'] = List.from(schema['required']);
        }
        final props = schema['properties'];
        if (props is Map<String, dynamic>) {
          props.forEach((k, v) {
            out['properties'][k] = _resolveSchemaSimple(v, components);
          });
        }
      } else if (type == 'array') {
        out['items'] = _resolveSchemaSimple(schema['items'], components);
      }
    }
    return out;
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _convertOpenApiToToolPayload(
  Map<String, dynamic> openApi,
) {
  final tools = <Map<String, dynamic>>[];
  final paths = openApi['paths'];
  if (paths is! Map) return tools;
  paths.forEach((path, methods) {
    if (methods is! Map) return;
    methods.forEach((method, operation) {
      if (operation is Map && operation['operationId'] != null) {
        final tool = <String, dynamic>{
          'name': operation['operationId'],
          'description':
              operation['description'] ??
              operation['summary'] ??
              'No description available.',
          'parameters': {
            'type': 'object',
            'properties': <String, dynamic>{},
            'required': <dynamic>[],
          },
        };
        // Parameters
        final params = operation['parameters'];
        if (params is List) {
          for (final p in params) {
            if (p is Map) {
              final name = p['name'];
              final schema = p['schema'] as Map?;
              if (name != null && schema != null) {
                String desc = (schema['description'] ?? p['description'] ?? '')
                    .toString();
                if (schema['enum'] is List) {
                  desc =
                      '$desc. Possible values: ${(schema['enum'] as List).join(', ')}';
                }
                tool['parameters']['properties'][name] = {
                  'type': schema['type'],
                  'description': desc,
                };
                if (p['required'] == true) {
                  (tool['parameters']['required'] as List).add(name);
                }
              }
            }
          }
        }
        // requestBody
        final reqBody = operation['requestBody'];
        if (reqBody is Map) {
          final content = reqBody['content'];
          if (content is Map && content['application/json'] is Map) {
            final schema = content['application/json']['schema'];
            final resolved = _resolveSchemaSimple(
              schema,
              openApi['components'] as Map<String, dynamic>?,
            );
            if (resolved['properties'] is Map) {
              tool['parameters']['properties'] = {
                ...tool['parameters']['properties'],
                ...resolved['properties'] as Map<String, dynamic>,
              };
              if (resolved['required'] is List) {
                final req = Set.from(tool['parameters']['required'] as List)
                  ..addAll(resolved['required'] as List);
                tool['parameters']['required'] = req.toList();
              }
            } else if (resolved['type'] == 'array') {
              tool['parameters'] = resolved;
            }
          }
        }
        tools.add(tool);
      }
    });
  });
  return tools;
}

/// Builds the `model_item` map from real server model data.
///
/// Includes routing-critical fields (`pipe`, `actions`, `owned_by`, etc.)
/// preserved during model parsing. The backend uses these for pipe routing,
/// filter resolution, and action dispatch.
Map<String, dynamic> _buildLocalModelItem(
  dynamic selectedModel, {
  DirectModelBinding? trustedDirectBinding,
  String? wireModelId,
}) {
  final meta = selectedModel.metadata as Map<String, dynamic>?;
  final openWebUiDirectBinding =
      trustedDirectBinding?.source == DirectModelSource.openWebUi
      ? trustedDirectBinding
      : null;
  return {
    'id': wireModelId ?? selectedModel.id,
    'name': selectedModel.name,
    if (openWebUiDirectBinding != null) ...{
      'direct': true,
      'urlIdx': openWebUiDirectBinding.openWebUiUrlIndex,
      'openai': {'id': openWebUiDirectBinding.remoteModelId},
      'connection_type': 'external',
    },
    'supported_parameters':
        selectedModel.supportedParameters ??
        [
          'max_tokens',
          'tool_choice',
          'tools',
          'response_format',
          'structured_outputs',
        ],
    'capabilities': selectedModel.capabilities,
    'info': meta?['info'],
    if (meta?['params'] != null) 'params': meta!['params'],
    if (meta?['base_model_id'] != null) 'base_model_id': meta!['base_model_id'],
    // Routing-critical fields for pipe models
    if (meta?['pipe'] != null) 'pipe': meta!['pipe'],
    if (meta?['actions'] != null) 'actions': meta!['actions'],
    if (meta?['owned_by'] != null) 'owned_by': meta!['owned_by'],
    if (meta?['object'] != null) 'object': meta!['object'],
    if (meta?['created'] != null) 'created': meta!['created'],
    if (meta?['has_user_valves'] != null)
      'has_user_valves': meta!['has_user_valves'],
    if (meta?['tags'] != null) 'tags': meta!['tags'],
    // Include filters for outlet filter routing
    if (selectedModel.filters != null)
      'filters': (selectedModel.filters as List)
          .map((f) => f.toJson())
          .toList(),
  };
}

@visibleForTesting
Map<String, dynamic> buildLocalModelItemForTest(Model selectedModel) =>
    _buildLocalModelItem(selectedModel);

/// Lets Open WebUI's `execute:tool` callbacks for the completion of
/// [messageId] in [chatId] reach the connections that request sent.
///
/// Called where the request leaves, after the connections were resolved, so the
/// admission is exactly the `tool_servers` of that request and exists before
/// the server can call back. A request that sent no connection, or that goes
/// over HTTP without a socket session, admits nothing.
void _admitPersonalToolServers(
  SocketService? socket, {
  required String? sessionId,
  required String? chatId,
  required String messageId,
  required List<PersonalToolAdmission> admitted,
}) {
  if (socket == null || admitted.isEmpty) return;
  socket.admitPersonalToolServers(
    chatId: chatId,
    messageId: messageId,
    sessionId: sessionId,
    connections: admitted,
  );
}
