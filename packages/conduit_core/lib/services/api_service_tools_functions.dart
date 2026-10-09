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

  /// Null when the function is inactive or declares no `UserValves`, and for
  /// Conduit Push, whose user valves only the push coordinator edits.
  Future<WorkspaceValveSpec?> getUserFunctionValvesSpec(
    String functionId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    if (functionId == kConduitPushFunctionId) return null;
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
