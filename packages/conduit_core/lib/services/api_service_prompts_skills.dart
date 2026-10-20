part of 'api_service.dart';

mixin _PromptsSkillsApi on _ApiServiceBase {
  // Suggestions
  Future<List<String>> getSuggestions() async {
    _traceApi('Fetching conversation suggestions');
    final data = await _loadPromptSuggestionConfig();
    final suggestions = data?['default_prompt_suggestions'];
    if (suggestions is List) {
      return suggestions
          .map(_promptSuggestionToString)
          .whereType<String>()
          .toList(growable: false);
    }
    return _loadLegacyPromptSuggestions();
  }

  Future<WorkspacePagedResponse<WorkspaceSkillSummary>> getWorkspaceSkills({
    String? query,
    String? viewOption,
    int page = 1,
  }) async {
    final response = await _dio.get(
      '/api/v1/skills/list',
      queryParameters: _workspaceListQuery(
        query: query,
        viewOption: viewOption,
        page: page,
      ),
    );
    return WorkspacePagedResponse.fromJson(
      response.data,
      WorkspaceSkillSummary.fromJson,
    );
  }

  Future<WorkspaceSkillDetail?> getWorkspaceSkill(String id) async {
    final response = await _dio.get('/api/v1/skills/id/$id');
    return response.data is Map
        ? WorkspaceSkillSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceSkillDetail?> createWorkspaceSkill(
    WorkspaceSkillForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/skills/create',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceSkillSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceSkillDetail?> updateWorkspaceSkill(
    String id,
    WorkspaceSkillForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/skills/id/$id/update',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceSkillSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceSkillDetail?> updateWorkspaceSkillAccess(
    String id,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    final response = await _dio.post(
      '/api/v1/skills/id/$id/access/update',
      data: {'access_grants': workspaceGrantInputs(grants)},
    );
    return response.data is Map
        ? WorkspaceSkillSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<List<WorkspaceSkillDetail>> exportWorkspaceSkills() async {
    final response = await _dio.get('/api/v1/skills/export');
    return workspaceJsonList(response.data)
        .map(WorkspaceSkillSummary.fromJson)
        .toList(growable: false);
  }

  Future<WorkspaceSkillDetail?> toggleWorkspaceSkill(String id) async {
    final response = await _dio.post('/api/v1/skills/id/$id/toggle');
    return response.data is Map
        ? WorkspaceSkillSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<bool> deleteWorkspaceSkill(String id) async {
    final response = await _dio.delete('/api/v1/skills/id/$id/delete');
    return response.data == true;
  }

  // Prompts
  Future<List<Prompt>> getPrompts() async {
    _traceApi('Fetching prompts');
    final response = await _dio.get('/api/v1/prompts/');
    final data = response.data;
    if (data is List) {
      final normalized = await _normalizeList(
        data,
        debugLabel: 'parse_prompts',
      );
      return normalized
          .map(Prompt.fromJson)
          .where((prompt) => prompt.command.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  Future<WorkspacePagedResponse<WorkspacePromptSummary>> getWorkspacePrompts({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) async {
    final response = await _dio.get(
      '/api/v1/prompts/list',
      queryParameters: _workspaceListQuery(
        query: query,
        viewOption: viewOption,
        tag: tag,
        orderBy: orderBy,
        direction: direction,
        page: page,
      ),
    );
    return WorkspacePagedResponse.fromJson(
      response.data,
      WorkspacePromptSummary.fromJson,
    );
  }

  Future<WorkspacePromptDetail?> getWorkspacePrompt(String id) async {
    final response = await _dio.get('/api/v1/prompts/id/$id');
    return response.data is Map
        ? WorkspacePromptSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspacePromptDetail?> createWorkspacePrompt(
    WorkspacePromptForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/prompts/create',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspacePromptSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspacePromptDetail?> updateWorkspacePrompt(
    String id,
    WorkspacePromptForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/prompts/id/$id/update',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspacePromptSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspacePromptDetail?> updateWorkspacePromptAccess(
    String id,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    final response = await _dio.post(
      '/api/v1/prompts/id/$id/access/update',
      data: {'access_grants': workspaceGrantInputs(grants)},
    );
    return response.data is Map
        ? WorkspacePromptSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspacePromptDetail?> updateWorkspacePromptMetadata(
    String id, {
    required String name,
    required String command,
    List<String> tags = const [],
  }) async {
    final response = await _dio.post(
      '/api/v1/prompts/id/$id/update/meta',
      data: {'name': name, 'command': command, 'tags': tags},
    );
    return response.data is Map
        ? WorkspacePromptSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspacePromptDetail?> setWorkspacePromptVersion(
    String id,
    String versionId,
  ) async {
    final response = await _dio.post(
      '/api/v1/prompts/id/$id/update/version',
      data: {'version_id': versionId},
    );
    return response.data is Map
        ? WorkspacePromptSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspacePromptDetail?> toggleWorkspacePrompt(String id) async {
    final response = await _dio.post('/api/v1/prompts/id/$id/toggle');
    return response.data is Map
        ? WorkspacePromptSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<List<WorkspacePromptHistoryEntry>> getWorkspacePromptHistory(
    String id, {
    int page = 0,
  }) async {
    final response = await _dio.get(
      '/api/v1/prompts/id/$id/history',
      queryParameters: {'page': page < 0 ? 0 : page},
    );
    return workspaceJsonList(response.data)
        .map(WorkspacePromptHistoryEntry.fromJson)
        .toList(growable: false);
  }

  Future<WorkspacePromptHistoryEntry> getWorkspacePromptHistoryEntry(
    String promptId,
    String historyId,
  ) async {
    final response = await _dio.get(
      '/api/v1/prompts/id/$promptId/history/$historyId',
    );
    return WorkspacePromptHistoryEntry.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  Future<bool> deleteWorkspacePromptHistoryEntry(
    String promptId,
    String historyId,
  ) async {
    final response = await _dio.delete(
      '/api/v1/prompts/id/$promptId/history/$historyId',
    );
    return response.data == true;
  }

  Future<Map<String, dynamic>> getWorkspacePromptHistoryDiff(
    String promptId, {
    required String fromId,
    required String toId,
  }) async {
    final response = await _dio.get(
      '/api/v1/prompts/id/$promptId/history/diff',
      queryParameters: {'from_id': fromId, 'to_id': toId},
    );
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> deletePrompt(String id) async {
    final response = await _dio.delete('/api/v1/prompts/id/$id/delete');
    if (response.data == false) {
      throw StateError('Failed to delete prompt: $id');
    }
  }
}
