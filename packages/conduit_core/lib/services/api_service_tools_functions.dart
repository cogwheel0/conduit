part of 'api_service.dart';

mixin _ToolsFunctionsApi on _ApiServiceBase {
  // Tools & Functions
  Future<List<Map<String, dynamic>>> getTools() async {
    _traceApi('Fetching tools');
    final response = await _dio.get('/api/v1/tools/');
    return workspaceJsonList(response.data);
  }

  Future<List<WorkspaceToolSummary>> getWorkspaceTools() async {
    final response = await _dio.get('/api/v1/tools/list');
    return workspaceJsonList(response.data)
        .map(WorkspaceToolSummary.fromJson)
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> getFunctions() async {
    _traceApi('Fetching functions');
    final response = await _dio.get('/api/v1/functions/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<WorkspaceToolDetail?> createWorkspaceTool(
    WorkspaceToolForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/tools/create',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceToolSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  // Enhanced Tools Management Operations
  Future<Map<String, dynamic>> getTool(String toolId) async {
    _traceApi('Fetching tool details: $toolId');
    final response = await _dio.get('/api/v1/tools/id/$toolId');
    return response.data as Map<String, dynamic>;
  }

  Future<WorkspaceToolDetail?> updateWorkspaceTool(
    String toolId,
    WorkspaceToolForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/tools/id/$toolId/update',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceToolSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceToolDetail?> updateWorkspaceToolAccess(
    String toolId,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    final response = await _dio.post(
      '/api/v1/tools/id/$toolId/access/update',
      data: {'access_grants': workspaceGrantInputs(grants)},
    );
    return response.data is Map
        ? WorkspaceToolSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  /// Runs one request of the MCP App [app] through Open WebUI's app RPC
  /// (0.13 and later): `ui/resource`, `tools/call`, `resources/read` or
  /// `resources/list`. The server checks the app's binding, and that a tool
  /// the app calls is one it may call, and answers with the MCP result.
  /// Throws [McpAppRpcException] with the server's reason when it refuses.
  Future<Map<String, dynamic>> runMcpAppRequest(
    OpenWebUiMcpApp app, {
    required String method,
    Map<String, dynamic> params = const <String, dynamic>{},
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/tools/id/${Uri.encodeComponent('server:mcp:${app.serverId}')}'
        '/mcp/app/rpc',
        data: <String, dynamic>{
          'tool_name': app.toolName,
          'binding': app.binding,
          'method': method,
          'params': params,
        },
        cancelToken: cancelToken,
      );
      final data = response.data;
      if (data is! Map) {
        throw const McpAppRpcException('The app request returned nothing.');
      }
      return {for (final entry in data.entries) entry.key.toString(): entry.value};
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      final data = e.response?.data;
      final detail = data is Map ? data['detail'] : null;
      final status = e.response?.statusCode;
      throw McpAppRpcException(
        detail is String && detail.trim().isNotEmpty
            ? detail.trim()
            : status == null
            ? 'The app request failed.'
            : 'The app request failed ($status).',
      );
    }
  }

  /// Switches a tool on or off (Open WebUI 0.13 and later). A tool switched
  /// off cannot be picked or run in any chat.
  Future<WorkspaceToolDetail?> toggleWorkspaceTool(String toolId) async {
    final response = await _dio.post('/api/v1/tools/id/$toolId/toggle');
    return response.data is Map
        ? WorkspaceToolSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<void> deleteTool(String toolId) async {
    _traceApi('Deleting tool: $toolId');
    await _dio.delete('/api/v1/tools/id/$toolId/delete');
  }

  Future<Map<String, dynamic>> getToolValves(String toolId) async {
    _traceApi('Fetching tool valves: $toolId');
    final response = await _dio.get('/api/v1/tools/id/$toolId/valves');
    return response.data as Map<String, dynamic>;
  }

  Future<WorkspaceValveSpec?> getToolValvesSpec(String toolId) async {
    final response = await _dio.get('/api/v1/tools/id/$toolId/valves/spec');
    return response.data is Map
        ? WorkspaceValveSpec.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<Map<String, dynamic>> updateToolValves(
    String toolId,
    Map<String, dynamic> valves,
  ) async {
    _traceApi('Updating tool valves: $toolId');
    final response = await _dio.post(
      '/api/v1/tools/id/$toolId/valves/update',
      data: valves,
    );
    return response.data as Map<String, dynamic>;
  }

  // The personal valve methods take an [ApiAuthSnapshot] so a request queued
  // for one account is rejected, not re-signed, if the shared client rotates to
  // another account before dispatch.

  Future<Map<String, dynamic>> getUserToolValves(
    String toolId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching user tool valves: $toolId');
    final response = await _dio.get(
      '/api/v1/tools/id/$toolId/valves/user',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _nullableJsonMap(response.data) ?? <String, dynamic>{};
  }

  Future<WorkspaceValveSpec?> getUserToolValvesSpec(
    String toolId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final response = await _dio.get(
      '/api/v1/tools/id/$toolId/valves/user/spec',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return response.data is Map
        ? WorkspaceValveSpec.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<Map<String, dynamic>> updateUserToolValves(
    String toolId,
    Map<String, dynamic> valves, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Updating user tool valves: $toolId');
    final response = await _dio.post(
      '/api/v1/tools/id/$toolId/valves/user/update',
      data: valves,
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _nullableJsonMap(response.data) ?? <String, dynamic>{};
  }

  // Personal (per-user) function valves. These routes need only a verified
  // user; the function is addressed by its real id, never a pipe model id.

  Future<Map<String, dynamic>?> getUserFunctionValves(
    String functionId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final response = await _dio.get(
      '/api/v1/functions/id/$functionId/valves/user',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _nullableJsonMap(response.data);
  }

  /// Null when the function is inactive or declares no `UserValves`.
  Future<WorkspaceValveSpec?> getUserFunctionValvesSpec(
    String functionId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final response = await _dio.get(
      '/api/v1/functions/id/$functionId/valves/user/spec',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    final spec = _nullableJsonMap(response.data);
    return spec == null ? null : WorkspaceValveSpec.fromJson(spec);
  }

  Future<Map<String, dynamic>?> updateUserFunctionValves(
    String functionId,
    Map<String, dynamic> valves, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/valves/user/update',
      data: valves,
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _nullableJsonMap(response.data);
  }

  static Map<String, dynamic>? _nullableJsonMap(Object? data) =>
      data is Map ? Map<String, dynamic>.from(data) : null;

  Future<List<Map<String, dynamic>>> exportTools() async {
    _traceApi('Exporting tools configuration');
    final response = await _dio.get('/api/v1/tools/export');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> loadToolFromUrl(String url) async {
    _traceApi('Loading tool from URL: $url');
    final response = await _dio.post(
      '/api/v1/tools/load/url',
      data: {'url': url},
    );
    return response.data as Map<String, dynamic>;
  }
}
