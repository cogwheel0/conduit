part of 'api_service.dart';

mixin _ModelsApi on _ApiServiceBase {
  // Models
  @override
  Future<List<Model>> getModels({bool includeHidden = false}) async {
    final response = await _dio.get('/api/models');

    // Normalize common response formats:
    // - {"data": [...]} (OpenAI)
    // - {"models": [...]} (some proxies)
    // - [...] (raw array)
    // - String payloads that need JSON decoding
    dynamic payload = response.data;
    if (payload is String) {
      try {
        payload = json.decode(payload);
      } catch (_) {}
    }

    final payloadMap = _coerceJsonMap(payload);
    List<dynamic>? rawModels;
    if (payloadMap != null) {
      rawModels =
          _asListOrNull(payloadMap['data']) ??
          _asListOrNull(payloadMap['models']);
    } else {
      rawModels = _asListOrNull(payload);
    }

    if (rawModels == null) {
      DebugLogger.error(
        'models-format',
        scope: 'api/models',
        data: {'type': payload.runtimeType},
      );
      return const [];
    }

    final models = <Model>[];
    var hiddenModelCount = 0;
    for (final raw in rawModels) {
      try {
        if (raw is String) {
          models.add(Model(id: raw, name: raw, supportsStreaming: true));
          continue;
        }
        if (raw is Map) {
          final normalized = raw.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final model = Model.fromJson(normalized);
          if (model.isHidden) {
            hiddenModelCount++;
          }
          if (model.isHidden && !includeHidden) {
            continue;
          }
          models.add(model);
          continue;
        }
        DebugLogger.warning(
          'models-entry-unknown',
          scope: 'api/models',
          data: {'type': raw.runtimeType},
        );
      } catch (error, stackTrace) {
        DebugLogger.error(
          'model-parse-failed',
          scope: 'api/models',
          error: error,
          stackTrace: stackTrace,
          data: {'type': raw.runtimeType},
        );
      }
    }

    DebugLogger.log(
      'models-count',
      scope: 'api/models',
      data: {'count': models.length, 'hidden': hiddenModelCount},
    );
    return models;
  }

  // Get default model configuration from OpenWebUI user settings
  Future<String?> getDefaultModel() async {
    try {
      final settings = await getServerUserSettingsModel();
      final defaultModel = settings.defaultModelId;
      if (defaultModel != null) {
        DebugLogger.log(
          'default-model',
          scope: 'api/user-settings',
          data: {'id': defaultModel, 'source': 'user-settings'},
        );
        return defaultModel;
      }
    } catch (e) {
      DebugLogger.error(
        'default-model-error',
        scope: 'api/user-settings',
        error: e,
      );
    }

    try {
      final response = await _dio.get('/api/config');
      final config = _coerceResponseMap(response.data);
      final defaultModels = _coerceConfigStringList(config?['default_models']);
      if (defaultModels.isNotEmpty) {
        final defaultModel = defaultModels.first;
        DebugLogger.log(
          'default-model',
          scope: 'api/user-settings',
          data: {'id': defaultModel, 'source': 'server-config'},
        );
        return defaultModel;
      }
    } catch (e) {
      DebugLogger.error(
        'default-model-config-error',
        scope: 'api/user-settings',
        error: e,
      );
    }

    DebugLogger.log('default-model-fallback', scope: 'api/user-settings');
    return _getFirstAvailableModelId();
  }

  // Get detailed model information
  Future<Map<String, dynamic>?> getModelDetails(String modelId) async {
    try {
      final response = await _dio.get(
        '/api/v1/models/model',
        queryParameters: {'id': modelId},
      );

      if (response.statusCode == 200 && response.data != null) {
        final modelData = response.data as Map<String, dynamic>;
        DebugLogger.log('details', scope: 'api/models', data: {'id': modelId});
        return modelData;
      }
    } catch (e) {
      _traceApi('Failed to get model details for $modelId: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> updateModel(Map<String, dynamic> model) async {
    final payload = <String, dynamic>{
      'id': model['id'],
      'base_model_id': model['base_model_id'],
      'name': model['name'],
      'meta': _coerceJsonMap(model['meta']) ?? <String, dynamic>{},
      'params': _coerceJsonMap(model['params']) ?? <String, dynamic>{},
      'access_grants': model['access_grants'],
      'is_active': model['is_active'],
    };
    payload.removeWhere((_, value) => value == null);

    final response = await _dio.post(
      '/api/v1/models/model/update',
      data: payload,
    );
    final data = response.data;
    return data is Map<String, dynamic> ? data : null;
  }

  Future<Map<String, dynamic>?> updateModelSystemPrompt(
    String modelId,
    String? systemPrompt,
  ) async {
    final model = await getModelDetails(modelId);
    if (model == null) {
      throw StateError('Model "$modelId" has no editable server record.');
    }

    final params = _coerceJsonMap(model['params']) ?? <String, dynamic>{};
    final trimmed = systemPrompt?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      params.remove('system');
    } else {
      params['system'] = trimmed;
    }

    final updated = await updateModel({...model, 'params': params});
    if (updated == null) {
      throw StateError('Model "$modelId" update returned no server record.');
    }
    return updated;
  }

  Future<WorkspacePagedResponse<WorkspaceModelSummary>> getWorkspaceModels({
    String? query,
    String? viewOption,
    String? tag,
    String? orderBy,
    String? direction,
    int page = 1,
  }) async {
    final response = await _dio.get(
      '/api/v1/models/list',
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
      WorkspaceModelSummary.fromJson,
    );
  }

  Future<WorkspaceModelDetail?> getWorkspaceModel(String id) async {
    final response = await _dio.get(
      '/api/v1/models/model',
      queryParameters: {'id': id},
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceModelDetail?> createWorkspaceModel(
    WorkspaceModelForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/models/create',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceModelDetail?> updateWorkspaceModel(
    WorkspaceModelForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/models/model/update',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceModelDetail?> updateWorkspaceModelAccess(
    String id,
    String name,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    final response = await _dio.post(
      '/api/v1/models/model/access/update',
      data: {
        'id': id,
        'name': name,
        'access_grants': workspaceGrantInputs(grants),
      },
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<List<WorkspaceModelDetail>> exportWorkspaceModels() async {
    final response = await _dio.get('/api/v1/models/export');
    return workspaceJsonList(response.data)
        .map(WorkspaceModelSummary.fromJson)
        .toList(growable: false);
  }

  Future<bool> importWorkspaceModels(List<Map<String, dynamic>> models) async {
    final response = await _dio.post(
      '/api/v1/models/import',
      data: {'models': models},
    );
    return response.data == true;
  }

  Future<List<WorkspaceModelDetail>> syncWorkspaceModels() async {
    final response = await _dio.post('/api/v1/models/sync');
    return workspaceJsonList(response.data)
        .map(WorkspaceModelSummary.fromJson)
        .toList(growable: false);
  }

  /// Base models available to compose custom workspace models from. Open WebUI
  /// serves these at `/api/v1/models/base` (the raw connections/pipelines,
  /// distinct from the user-facing `/models/list`).
  Future<List<WorkspaceModelSummary>> getWorkspaceBaseModels() async {
    final response = await _dio.get('/api/v1/models/base');
    return workspaceJsonList(response.data)
        .map(WorkspaceModelSummary.fromJson)
        .toList(growable: false);
  }

  /// Fetches a model's profile image bytes from the dedicated
  /// `/api/v1/models/model/profile/image` endpoint. Returns null when the
  /// server has no stored image (or serves a redirect to a remote URL).
  Future<List<int>?> getWorkspaceModelProfileImage(String id) async {
    try {
      final response = await _dio.get<List<int>>(
        '/api/v1/models/model/profile/image',
        queryParameters: {'id': id},
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: false,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final data = response.data;
      return data == null || data.isEmpty ? null : data;
    } on DioException {
      return null;
    }
  }

  Future<WorkspaceModelDetail?> toggleWorkspaceModel(String id) async {
    final response = await _dio.post(
      '/api/v1/models/model/toggle',
      queryParameters: {'id': id},
    );
    return response.data is Map
        ? WorkspaceModelSummary.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<bool> deleteWorkspaceModel(String id) async {
    final response = await _dio.post(
      '/api/v1/models/model/delete',
      data: {'id': id},
    );
    return response.data == true;
  }
}
