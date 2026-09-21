part of 'api_service.dart';

mixin _KnowledgeBasesApi on _ApiServiceBase {
  Future<List<KnowledgeBase>> getKnowledgeBases() async {
    _traceApi('Fetching knowledge bases');
    final response = await _dio.get('/api/v1/knowledge/');
    final data = response.data;

    // Handle new paginated response: { "items": [...], "total": N }
    // Also maintain backward compatibility with old array response
    List<dynamic> items;
    if (data is Map<String, dynamic> && data.containsKey('items')) {
      items = data['items'] as List<dynamic>? ?? [];
    } else if (data is List) {
      // Backward compatibility with old API
      items = data;
    } else {
      return const [];
    }

    final normalized = await _normalizeList(
      items,
      debugLabel: 'parse_knowledge_bases',
    );
    return normalized.map(KnowledgeBase.fromJson).toList(growable: false);
  }

  Future<void> deleteKnowledgeBase(String id) async {
    _traceApi('Deleting knowledge base: $id');
    try {
      final response = await _dio.delete('/api/v1/knowledge/$id/delete');
      if (response.data is bool && response.data == false) {
        throw StateError('Failed to delete knowledge base: $id');
      }
    } on DioException catch (error) {
      if (!_shouldFallbackToLegacyKnowledgeApi(error)) {
        rethrow;
      }
      await _dio.delete('/api/v1/knowledge/$id');
    }
  }

  Future<List<KnowledgeBaseItem>> getKnowledgeBaseItems(
    String knowledgeBaseId,
  ) async {
    _traceApi('Fetching knowledge base items: $knowledgeBaseId');
    final rawItems = <dynamic>[];
    var page = 1;
    int? total;
    const maxPages = 100;
    var useLegacyItemsFallback = false;

    try {
      while (true) {
        final response = await _dio.get(
          '/api/v1/knowledge/$knowledgeBaseId/files',
          queryParameters: {'page': page, 'include_content': true},
        );
        final data = response.data;
        if (data is List) {
          rawItems.addAll(data);
          break;
        }

        final responseMap = _coerceJsonMap(data);
        if (responseMap == null) {
          useLegacyItemsFallback = true;
          break;
        }
        final pageItems = responseMap['items'] is List
            ? responseMap['items'] as List
            : const <dynamic>[];
        rawItems.addAll(pageItems);
        final rawTotal = responseMap['total'];
        if (rawTotal is int) {
          total = rawTotal;
        } else if (rawTotal is num) {
          total = rawTotal.toInt();
        }

        if (pageItems.isEmpty || (total != null && rawItems.length >= total)) {
          break;
        }
        page += 1;
        if (page > maxPages) {
          _traceApi(
            'Warning: Hit max knowledge item page limit '
            '($maxPages) for $knowledgeBaseId',
          );
          break;
        }
      }
    } on DioException catch (error) {
      if (!_shouldFallbackToLegacyKnowledgeApi(error)) {
        rethrow;
      }
      useLegacyItemsFallback = true;
    }

    if (useLegacyItemsFallback) {
      rawItems.clear();
      final response = await _dio.get(
        '/api/v1/knowledge/$knowledgeBaseId/items',
      );
      final data = response.data;
      if (data is List) {
        rawItems
          ..clear()
          ..addAll(data);
      }
    }

    if (rawItems.isNotEmpty) {
      final normalized = await _normalizeList(
        rawItems,
        debugLabel: 'parse_kb_items',
      );
      return normalized.map(_knowledgeEntryToItem).toList(growable: false);
    }
    return const [];
  }

  /// Search knowledge bases globally.
  Future<List<Map<String, dynamic>>> searchKnowledgeBases({
    String? query,
    String? viewOption,
    int? page,
  }) async {
    _traceApi('Searching knowledge bases: $query');
    final queryParams = <String, dynamic>{};
    if (query != null && query.isNotEmpty) {
      queryParams['query'] = query;
    }
    if (viewOption != null && viewOption.isNotEmpty) {
      queryParams['view_option'] = viewOption;
    }
    if (page != null) {
      queryParams['page'] = page;
    }

    final response = await _dio.get(
      '/api/v1/knowledge/search',
      queryParameters: queryParams.isEmpty ? null : queryParams,
    );
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final items = data['items'];
      if (items is List) {
        return items.whereType<Map<String, dynamic>>().toList(growable: false);
      }
    } else if (data is List) {
      return data.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  /// Search knowledge files globally.
  Future<List<Map<String, dynamic>>> searchKnowledgeFiles({
    String? query,
    String? viewOption,
    String? orderBy,
    String? direction,
    int page = 1,
  }) async {
    _traceApi('Searching knowledge files: $query');
    final queryParams = <String, dynamic>{'page': page};
    if (query != null && query.isNotEmpty) {
      queryParams['query'] = query;
    }
    if (viewOption != null && viewOption.isNotEmpty) {
      queryParams['view_option'] = viewOption;
    }
    if (orderBy != null && orderBy.isNotEmpty) {
      queryParams['order_by'] = orderBy;
    }
    if (direction != null && direction.isNotEmpty) {
      queryParams['direction'] = direction;
    }

    final response = await _dio.get(
      '/api/v1/knowledge/search/files',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final items = data['items'];
      if (items is List) {
        return items.whereType<Map<String, dynamic>>().toList(growable: false);
      }
    } else if (data is List) {
      return data.whereType<Map<String, dynamic>>().toList(growable: false);
    }
    return const <Map<String, dynamic>>[];
  }

  /// Fetches files for a knowledge base with pagination support.
  ///
  /// Returns a record with the list of files and the total count.
  /// The new API returns paginated results (default 30 items per page).
  Future<({List<KnowledgeBaseFile> files, int total})> getKnowledgeBaseFiles(
    String knowledgeBaseId, {
    int page = 1,
  }) async {
    _traceApi('Fetching knowledge base files: $knowledgeBaseId (page: $page)');
    final response = await _dio.get(
      '/api/v1/knowledge/$knowledgeBaseId/files',
      queryParameters: {'page': page},
    );
    final data = response.data;

    if (data is Map<String, dynamic>) {
      final items = data['items'] as List<dynamic>? ?? [];
      final total = data['total'] as int? ?? items.length;
      final files = items
          .whereType<Map<String, dynamic>>()
          .map(KnowledgeBaseFile.fromJson)
          .toList(growable: false);
      return (files: files, total: total);
    }

    // Backward compatibility: if response is a plain list
    if (data is List) {
      final files = data
          .whereType<Map<String, dynamic>>()
          .map(KnowledgeBaseFile.fromJson)
          .toList(growable: false);
      return (files: files, total: files.length);
    }

    return (files: const <KnowledgeBaseFile>[], total: 0);
  }

  /// Fetches ALL files for a knowledge base, handling pagination internally.
  ///
  /// Use this when you need the complete list of files (e.g., for deduplication).
  Future<List<KnowledgeBaseFile>> getAllKnowledgeBaseFiles(
    String knowledgeBaseId,
  ) async {
    _traceApi('Fetching all knowledge base files: $knowledgeBaseId');
    final allFiles = <KnowledgeBaseFile>[];
    int page = 1;
    int total = 0;
    const maxPages = 100; // Safety limit to prevent infinite loops

    do {
      final result = await getKnowledgeBaseFiles(knowledgeBaseId, page: page);
      // Guard against empty pages causing infinite loops
      if (result.files.isEmpty) {
        _traceApi('Empty page received, stopping pagination');
        break;
      }
      allFiles.addAll(result.files);
      total = result.total;
      page++;
    } while (allFiles.length < total && page <= maxPages);

    if (page > maxPages) {
      _traceApi('Warning: Hit max page limit ($maxPages) for $knowledgeBaseId');
    }
    _traceApi('Fetched ${allFiles.length} total files from $knowledgeBaseId');
    return allFiles;
  }
}
