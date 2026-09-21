part of 'api_service.dart';

mixin _FoldersTagsApi on _ApiServiceBase {
  // Folders
  /// Returns a record with (folders data, feature enabled flag).
  /// When the folders feature is disabled server-side (403), returns ([], false).
  Future<(List<Map<String, dynamic>>, bool)> getFolders() async {
    try {
      final response = await _dio.get('/api/v1/folders/');
      DebugLogger.log(
        'fetch-status',
        scope: 'api/folders',
        data: {'code': response.statusCode},
      );
      DebugLogger.log('fetch-ok', scope: 'api/folders');

      final data = response.data;
      if (data is List) {
        _traceApi('Found ${data.length} folders');
        return (data.cast<Map<String, dynamic>>(), true);
      } else {
        DebugLogger.warning(
          'unexpected-type',
          scope: 'api/folders',
          data: {'type': data.runtimeType},
        );
        return (const <Map<String, dynamic>>[], true);
      }
    } on DioException catch (e) {
      // 403 indicates folders feature is disabled server-side
      if (e.response?.statusCode == 403) {
        DebugLogger.log(
          'feature-disabled',
          scope: 'api/folders',
          data: {'status': 403},
        );
        return (const <Map<String, dynamic>>[], false);
      }
      DebugLogger.error('fetch-failed', scope: 'api/folders', error: e);
      rethrow;
    } catch (e) {
      DebugLogger.error('fetch-failed', scope: 'api/folders', error: e);
      rethrow;
    }
  }

  /// GET `/api/v1/folders/shared` — folders another user granted to this
  /// account (`routers/folders.py:get_shared_folders`), each carrying
  /// `owner_name` and `permission` (`read`|`write`). Children of a shared
  /// folder are included by the server. Returns `[]` on 403 (feature off) and
  /// 404 (server predates the route).
  Future<List<Map<String, dynamic>>> getSharedFolders() async {
    try {
      final response = await _dio.get('/api/v1/folders/shared');
      return _coerceRawMapList(response.data);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 403 || code == 404) {
        DebugLogger.log(
          'shared-unavailable',
          scope: 'api/folders',
          data: {'status': code},
        );
        return const <Map<String, dynamic>>[];
      }
      rethrow;
    }
  }

  /// GET `/api/v1/folders/{id}/shared/chats?page=N` — one page (10) of chat
  /// list entries inside a folder, for the owner and for anyone it is shared
  /// with (`routers/folders.py:get_shared_folder_chats`). Each item is a
  /// list-shaped chat map plus `user_id`, `owner_name` and `readonly`. Returns
  /// the page and the server's `has_more` flag.
  Future<(List<Map<String, dynamic>>, bool)> getSharedFolderChatsPage(
    String folderId, {
    required int page,
  }) async {
    final response = await _dio.get(
      '/api/v1/folders/${Uri.encodeComponent(folderId)}/shared/chats',
      queryParameters: {'page': page},
    );
    final data = response.data;
    final chats = data is Map ? data['chats'] : null;
    return (
      chats is List ? _coerceRawMapList(chats) : const <Map<String, dynamic>>[],
      data is Map && data['has_more'] == true,
    );
  }

  /// Every chat in a folder via [getSharedFolderChatsPage], newest first.
  /// Bounded so a runaway `has_more` can never loop forever.
  // ponytail: 50 pages = 500 chats; switch to a "show more" row if a folder
  // ever grows past that.
  Future<List<Map<String, dynamic>>> getSharedFolderChats(
    String folderId, {
    int maxPages = 50,
  }) async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= maxPages; page++) {
      final (chats, hasMore) = await getSharedFolderChatsPage(
        folderId,
        page: page,
      );
      all.addAll(chats);
      if (!hasMore || chats.isEmpty) break;
    }
    return all;
  }

  Future<Map<String, dynamic>> createFolder({
    required String name,
    String? parentId,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    _traceApi('Creating folder: $name');
    final response = await _dio.post(
      '/api/v1/folders/',
      data: {
        'name': name,
        'parent_id': ?parentId,
        'data': ?data,
        'meta': ?meta,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>?> getFolderById(String id) async {
    _traceApi('Fetching folder: $id');
    final response = await _dio.get('/api/v1/folders/$id');
    final data = response.data;
    return data is Map<String, dynamic> ? data : null;
  }

  Future<Map<String, dynamic>?> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    _traceApi('Updating folder: $id');
    final payload = <String, dynamic>{
      'name': ?name,
      'data': ?data,
      'meta': ?meta,
    };
    if (payload.isEmpty) {
      return null;
    }
    final response = await _dio.post(
      '/api/v1/folders/$id/update',
      data: payload,
    );
    final responseData = response.data;
    return responseData is Map<String, dynamic> ? responseData : null;
  }

  Future<void> updateFolderParent(String id, String? parentId) async {
    _traceApi('Updating folder parent: $id -> $parentId');
    await _dio.post(
      '/api/v1/folders/$id/update/parent',
      data: {'parent_id': parentId},
    );
  }

  Future<void> deleteFolder(String id) async {
    _traceApi('Deleting folder: $id');
    await _dio.delete('/api/v1/folders/$id');
  }

  Future<void> moveConversationToFolder(
    String conversationId,
    String? folderId,
  ) async {
    _traceApi('Moving conversation $conversationId to folder $folderId');
    await _dio.post(
      '/api/v1/chats/$conversationId/folder',
      data: {'folder_id': folderId},
    );
  }

  Future<void> addTagToConversation(String conversationId, String tag) async {
    _traceApi('Adding tag "$tag" to conversation: $conversationId');
    try {
      await _dio.post(
        '/api/v1/chats/$conversationId/tags',
        data: {'name': tag},
      );
    } on DioException catch (error) {
      if (!_shouldFallbackToLegacyTagApi(error)) {
        rethrow;
      }
      await _dio.post('/api/v1/chats/$conversationId/tags', data: {'tag': tag});
    }
  }

  Future<void> removeTagFromConversation(
    String conversationId,
    String tag,
  ) async {
    _traceApi('Removing tag "$tag" from conversation: $conversationId');
    try {
      await _dio.delete(
        '/api/v1/chats/$conversationId/tags',
        data: {'name': tag},
      );
    } on DioException catch (error) {
      if (!_shouldFallbackToLegacyTagApi(error)) {
        rethrow;
      }
      await _dio.delete(
        '/api/v1/chats/$conversationId/tags/${Uri.encodeComponent(tag)}',
      );
    }
  }

  Future<List<String>> getAllTags() async {
    _traceApi('Fetching all available tags');
    Response<dynamic> response;
    try {
      response = await _dio.get('/api/v1/chats/all/tags');
    } on DioException catch (error) {
      if (!_shouldFallbackToLegacyTagApi(error)) {
        rethrow;
      }
      response = await _dio.get('/api/v1/chats/tags');
    }
    final data = response.data;
    if (data is List) {
      return data.map(_tagNameFromEntry).whereType<String>().toList();
    }
    return [];
  }

  Future<List<Conversation>> getConversationsByTag(String tag) async {
    _traceApi('Fetching conversations with tag: $tag');
    try {
      const pageSize = 50;
      const maxPages = 100;
      final conversations = <Conversation>[];
      var skip = 0;
      var pageCount = 0;
      while (true) {
        final response = await _dio.post(
          '/api/v1/chats/tags',
          data: {'name': tag, 'skip': skip, 'limit': pageSize},
          options: Options(responseType: ResponseType.bytes),
        );
        final page = await _parseConversationSummaryPayload(
          regular: response.data,
          debugLabel: 'parse_tag_${tag}_skip_$skip',
        );
        conversations.addAll(page);
        if (page.length < pageSize) {
          break;
        }
        skip += pageSize;
        pageCount += 1;
        if (pageCount >= maxPages) {
          _traceApi('Warning: Hit max tag page limit ($maxPages) for $tag');
          break;
        }
      }
      return conversations;
    } on DioException catch (error) {
      if (!_shouldFallbackToLegacyTagApi(error)) {
        rethrow;
      }
      final response = await _dio.get(
        '/api/v1/chats/tags/${Uri.encodeComponent(tag)}',
        options: Options(responseType: ResponseType.bytes),
      );
      return _parseConversationSummaryPayload(
        regular: response.data,
        debugLabel: 'parse_tag_$tag',
      );
    }
  }
}
