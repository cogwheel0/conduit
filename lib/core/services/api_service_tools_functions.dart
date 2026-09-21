part of 'api_service.dart';

mixin _ToolsFunctionsApi on _ApiServiceBase {
  // Tools - Check available tools on server
  Future<List<Map<String, dynamic>>> getAvailableTools() async {
    _traceApi('Fetching available tools');
    try {
      final response = await _dio.get('/api/v1/tools/');
      final data = response.data;
      if (data is List) {
        return data.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      _traceApi('Error fetching tools: $e');
    }
    return [];
  }

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

  Future<Map<String, dynamic>> createTool({
    required String name,
    required Map<String, dynamic> spec,
    String? id,
    String? content,
    String? description,
  }) async {
    // Tool ids must be Python identifiers (letters/digits/underscore, no leading
    // digit); derive the fallback via nameToId rather than a hyphenated slug.
    final toolId = id ?? WorkspaceToolContent.nameToId(name);
    final source = content ?? spec['content']?.toString() ?? '';
    final created = await createWorkspaceTool(
      WorkspaceToolForm(
        id: toolId,
        name: name,
        content: source,
        meta: {
          'description': ?description,
          if (spec.isNotEmpty) 'manifest': spec,
        },
      ),
    );
    if (created == null) throw StateError('Tool create returned no record.');
    return <String, dynamic>{
      'id': created.id,
      'name': created.name,
      'meta': created.meta,
    };
  }

  Future<Map<String, dynamic>> createFunction({
    required String name,
    required String code,
    String? description,
  }) async {
    _traceApi('Creating function: $name');
    final response = await _dio.post(
      '/api/v1/functions/',
      data: {'name': name, 'code': code, 'description': ?description},
    );
    return response.data as Map<String, dynamic>;
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

  Future<Map<String, dynamic>> updateTool(
    String toolId, {
    String? name,
    Map<String, dynamic>? spec,
    String? content,
    String? description,
  }) async {
    final current = WorkspaceToolSummary.fromJson(await getTool(toolId));
    final updated = await updateWorkspaceTool(
      toolId,
      WorkspaceToolForm(
        id: toolId,
        name: name ?? current.name,
        content:
            content ?? spec?['content']?.toString() ?? current.content ?? '',
        meta: {...current.meta, 'description': ?description, 'manifest': ?spec},
        accessGrants: current.accessGrants
            .map(WorkspaceAccessGrantInput.fromGrant)
            .toList(growable: false),
      ),
    );
    if (updated == null) throw StateError('Tool update returned no record.');
    return <String, dynamic>{
      'id': updated.id,
      'name': updated.name,
      'content': updated.content,
      'meta': updated.meta,
    };
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

  // Enhanced Functions Management Operations
  Future<Map<String, dynamic>> getFunction(String functionId) async {
    _traceApi('Fetching function details: $functionId');
    final response = await _dio.get('/api/v1/functions/id/$functionId');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateFunction(
    String functionId, {
    String? name,
    String? code,
    String? description,
  }) async {
    _traceApi('Updating function: $functionId');
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/update',
      data: {'name': ?name, 'code': ?code, 'description': ?description},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> deleteFunction(String functionId) async {
    _traceApi('Deleting function: $functionId');
    await _dio.delete('/api/v1/functions/id/$functionId/delete');
  }

  Future<Map<String, dynamic>> toggleFunction(String functionId) async {
    _traceApi('Toggling function: $functionId');
    final response = await _dio.post('/api/v1/functions/id/$functionId/toggle');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> toggleGlobalFunction(String functionId) async {
    _traceApi('Toggling global function: $functionId');
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/toggle/global',
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getFunctionValves(String functionId) async {
    _traceApi('Fetching function valves: $functionId');
    final response = await _dio.get('/api/v1/functions/id/$functionId/valves');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateFunctionValves(
    String functionId,
    Map<String, dynamic> valves,
  ) async {
    _traceApi('Updating function valves: $functionId');
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/valves/update',
      data: valves,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getUserFunctionValves(String functionId) async {
    _traceApi('Fetching user function valves: $functionId');
    final response = await _dio.get(
      '/api/v1/functions/id/$functionId/valves/user',
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateUserFunctionValves(
    String functionId,
    Map<String, dynamic> valves,
  ) async {
    _traceApi('Updating user function valves: $functionId');
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/valves/user/update',
      data: valves,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> syncFunctions() async {
    _traceApi('Syncing functions');
    final response = await _dio.post('/api/v1/functions/sync');
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> exportFunctions() async {
    _traceApi('Exporting functions configuration');
    final response = await _dio.get('/api/v1/functions/export');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }
}
