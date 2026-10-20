part of 'api_service.dart';

mixin _WorkspaceKnowledgeApi on _ApiServiceBase {
  // Knowledge Base
  Future<WorkspacePagedResponse<WorkspaceKnowledgeSummary>>
  getWorkspaceKnowledge({
    String? query,
    String? viewOption,
    String? source,
    int page = 1,
  }) async {
    final normalizedQuery = query?.trim() ?? '';
    final normalizedView = viewOption?.trim() ?? '';
    final normalizedSource = source?.trim() ?? '';
    final isFiltered =
        normalizedQuery.isNotEmpty ||
        normalizedView.isNotEmpty ||
        normalizedSource.isNotEmpty;
    final response = await _dio.get(
      isFiltered ? '/api/v1/knowledge/search' : '/api/v1/knowledge/',
      queryParameters: {
        'page': page,
        if (normalizedQuery.isNotEmpty) 'query': normalizedQuery,
        if (normalizedView.isNotEmpty) 'view_option': normalizedView,
        if (normalizedSource.isNotEmpty) 'source': normalizedSource,
      },
    );
    return WorkspacePagedResponse.fromJson(
      response.data,
      WorkspaceKnowledgeSummary.fromJson,
    );
  }

  Future<WorkspaceKnowledgeDetail?> getWorkspaceKnowledgeDetail(
    String id,
  ) async {
    final response = await _dio.get('/api/v1/knowledge/$id');
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceKnowledgeDetail?> createWorkspaceKnowledge(
    WorkspaceKnowledgeForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/knowledge/create',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceKnowledgeDetail?> updateWorkspaceKnowledge(
    String id,
    WorkspaceKnowledgeForm form,
  ) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/update',
      data: form.toJson(),
    );
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceKnowledgeDetail?> updateWorkspaceKnowledgeAccess(
    String id,
    List<WorkspaceAccessGrantInput> grants,
  ) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/access/update',
      data: {'access_grants': workspaceGrantInputs(grants)},
    );
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceKnowledgeFilePage> getWorkspaceKnowledgeFiles(
    String id, {
    String? query,
    String? viewOption,
    String? orderBy,
    String? direction,
    String? directoryId,
    bool includeContent = false,
    int page = 1,
  }) async {
    final response = await _dio.get(
      '/api/v1/knowledge/$id/files',
      queryParameters: <String, dynamic>{
        'page': page,
        'include_content': includeContent,
        if (query != null && query.isNotEmpty) 'query': query,
        if (viewOption != null && viewOption.isNotEmpty)
          'view_option': viewOption,
        if (orderBy != null && orderBy.isNotEmpty) 'order_by': orderBy,
        if (direction != null && direction.isNotEmpty) 'direction': direction,
        'directory_id': ?directoryId,
      },
    );
    return WorkspaceKnowledgeFilePage.fromJson(response.data);
  }

  Future<List<WorkspacePendingFile>> getWorkspaceKnowledgePendingFiles(
    String id,
  ) async {
    final response = await _dio.get(
      '/api/v1/knowledge/$id/files/pending',
      queryParameters: const {'stream': false},
    );
    return workspaceJsonList(response.data)
        .map(WorkspacePendingFile.fromJson)
        .toList(growable: false);
  }

  Future<WorkspaceKnowledgeDetail?> attachWorkspaceKnowledgeFile(
    String id,
    String fileId, {
    String? directoryId,
  }) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/file/add',
      data: {'file_id': fileId, 'directory_id': directoryId},
    );
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceKnowledgeDetail?> reindexWorkspaceKnowledgeFile(
    String id,
    String fileId,
  ) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/file/update',
      data: {'file_id': fileId},
    );
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceKnowledgeDetail?> removeWorkspaceKnowledgeFile(
    String id,
    String fileId, {
    bool deleteFile = true,
  }) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/file/remove',
      queryParameters: {'delete_file': deleteFile},
      data: {'file_id': fileId},
    );
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceKnowledgeDetail?> attachWorkspaceKnowledgeFiles(
    String id,
    List<({String fileId, String? directoryId})> files,
  ) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/files/batch/add',
      data: files
          .map(
            (file) => {
              'file_id': file.fileId,
              'directory_id': file.directoryId,
            },
          )
          .toList(growable: false),
    );
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }

  Future<WorkspaceKnowledgeDirectory> createWorkspaceKnowledgeDirectory(
    String id, {
    required String name,
    String? parentId,
  }) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/dirs/create',
      data: {'name': name, 'parent_id': parentId},
    );
    return WorkspaceKnowledgeDirectory.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  Future<WorkspaceKnowledgeDirectory> updateWorkspaceKnowledgeDirectory(
    String id,
    String directoryId, {
    String? name,
    String? parentId,
    bool updateParent = false,
  }) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/dirs/$directoryId/update',
      data: {'name': ?name, if (updateParent) 'parent_id': parentId},
    );
    return WorkspaceKnowledgeDirectory.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  Future<bool> deleteWorkspaceKnowledgeDirectory(
    String id,
    String directoryId, {
    bool moveFiles = true,
  }) async {
    final response = await _dio.delete(
      '/api/v1/knowledge/$id/dirs/$directoryId/delete',
      queryParameters: {'move_files': moveFiles},
    );
    return workspaceJsonMap(response.data)['status'] == true;
  }

  Future<bool> moveWorkspaceKnowledgeFile(
    String id,
    String fileId, {
    String? directoryId,
  }) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/file/move',
      data: {'file_id': fileId, 'directory_id': directoryId},
    );
    return workspaceJsonMap(response.data)['status'] == true;
  }

  Future<WorkspaceSyncDiff> diffWorkspaceKnowledge(
    String id,
    List<Map<String, dynamic>> manifest,
  ) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/sync/diff',
      data: {'manifest': manifest},
    );
    return WorkspaceSyncDiff.fromJson(
      Map<String, dynamic>.from(response.data as Map),
    );
  }

  Future<bool> cleanupWorkspaceKnowledgeSync(
    String id, {
    required List<String> fileIds,
    List<String> directoryIds = const [],
  }) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/sync/cleanup',
      data: {'file_ids': fileIds, 'dir_ids': directoryIds},
    );
    return workspaceJsonMap(response.data)['status'] == true;
  }

  Future<List<int>> exportWorkspaceKnowledge(String id) async {
    final response = await _dio.get<List<int>>(
      '/api/v1/knowledge/$id/export',
      options: Options(responseType: ResponseType.bytes),
    );
    return response.data ?? const <int>[];
  }

  /// Removes every file (and optionally directories) from a knowledge base while
  /// keeping the base itself. Owner/write-access or admin only, server-enforced.
  Future<WorkspaceKnowledgeDetail?> resetWorkspaceKnowledge(
    String id, {
    bool includeDirectories = true,
  }) async {
    final response = await _dio.post(
      '/api/v1/knowledge/$id/reset',
      queryParameters: {'include_directories': includeDirectories},
    );
    return response.data is Map
        ? WorkspaceKnowledgeDetail.fromJson(
            Map<String, dynamic>.from(response.data as Map),
          )
        : null;
  }
}
