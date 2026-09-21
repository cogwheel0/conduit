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

  Future<Map<String, dynamic>> getUserToolValves(String toolId) async {
    _traceApi('Fetching user tool valves: $toolId');
    final response = await _dio.get('/api/v1/tools/id/$toolId/valves/user');
    return response.data as Map<String, dynamic>;
  }

  Future<WorkspaceValveSpec?> getUserToolValvesSpec(String toolId) async {
    final response = await _dio.get(
      '/api/v1/tools/id/$toolId/valves/user/spec',
    );
    return response.data is Map
        ? WorkspaceValveSpec.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<Map<String, dynamic>> updateUserToolValves(
    String toolId,
    Map<String, dynamic> valves,
  ) async {
    _traceApi('Updating user tool valves: $toolId');
    final response = await _dio.post(
      '/api/v1/tools/id/$toolId/valves/user/update',
      data: valves,
    );
    return response.data as Map<String, dynamic>;
  }

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
