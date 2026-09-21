part of 'api_service.dart';

mixin _ChatListsApi on _ApiServiceBase {
  // Conversations - Updated to use correct OpenWebUI API
  Future<List<Conversation>> getConversations({int? limit, int? skip}) async {
    final pinnedFuture = _fetchConversationSummaries(
      '/api/v1/chats/pinned',
      debugLabel: 'parse_pinned_conversations',
      pinned: true,
    );
    final archivedFuture = _fetchConversationSummaries(
      '/api/v1/chats/archived',
      debugLabel: 'parse_archived_conversations',
      archived: true,
    );

    List<Conversation> allRegularChats = [];

    if (limit == null) {
      // Fetch all conversations using parallel pagination for better performance
      // Main chats endpoint uses 50 items per page
      allRegularChats = await _fetchAllPagedConversationSummaries(
        endpoint: '/api/v1/chats/',
        baseParams: {'include_folders': true, 'include_pinned': true},
        expectedPageSize: 50,
        debugLabel: 'conversations',
      );
    } else {
      // Original single page fetch
      final pageQuery = <String, dynamic>{
        'include_folders': true,
        'include_pinned': true,
      };
      if (limit > 0) {
        pageQuery['page'] = (((skip ?? 0) / limit).floor() + 1).clamp(
          1,
          1 << 30,
        );
      }
      final regularResponse = await _dio.get(
        '/api/v1/chats/',
        // Convert skip/limit to 1-based page index expected by OpenWebUI.
        // Example: skip=0 => page=1, skip=limit => page=2, etc.
        queryParameters: pageQuery,
        options: Options(responseType: ResponseType.bytes),
      );
      allRegularChats = await _parseConversationSummaryPayload(
        regular: regularResponse.data,
        debugLabel: 'parse_conversation_page_single',
      );
    }

    final pinnedAndArchived = await Future.wait<List<Conversation>>([
      pinnedFuture,
      archivedFuture,
    ]);
    final pinnedChatList = pinnedAndArchived[0];
    final archivedChatList = pinnedAndArchived[1];
    final regularChatList = allRegularChats;

    DebugLogger.log(
      'summary',
      scope: 'api/conversations',
      data: {
        'regular': regularChatList.length,
        'pinned': pinnedChatList.length,
        'archived': archivedChatList.length,
      },
    );

    final conversations = _mergeConversationSummaries(
      pinned: pinnedChatList,
      archived: archivedChatList,
      regular: regularChatList,
    );

    DebugLogger.log(
      'parse-complete',
      scope: 'api/conversations',
      data: {
        'total': conversations.length,
        'pinned': conversations.where((c) => c.pinned).length,
        'archived': conversations.where((c) => c.archived).length,
      },
    );
    return conversations;
  }

  /// Fetches a single page of chat summaries for sidebar pagination.
  ///
  /// This mirrors OpenWebUI's sidebar behavior where the main chat list loads
  /// incrementally, while pinned/archived sections are fetched separately.
  Future<List<Conversation>> getConversationPage({
    int page = 1,
    bool includeFolders = true,
    bool includePinned = false,
  }) async {
    final safePage = page < 1 ? 1 : page;
    _traceApi('Fetching conversation page: $safePage');

    final queryParams = <String, dynamic>{'page': safePage};
    if (includeFolders) {
      queryParams['include_folders'] = true;
    }
    if (includePinned) {
      queryParams['include_pinned'] = true;
    }

    final response = await _dio.get(
      '/api/v1/chats/',
      queryParameters: queryParams,
      options: Options(responseType: ResponseType.bytes),
    );
    return _parseConversationSummaryPayload(
      regular: response.data,
      debugLabel: 'parse_conversation_page_$safePage',
    );
  }

  /// Fetches pinned chat summaries for the sidebar.
  Future<List<Conversation>> getPinnedConversationSummaries() async {
    return _fetchConversationSummaries(
      '/api/v1/chats/pinned',
      debugLabel: 'parse_pinned_conversations',
      pinned: true,
    );
  }

  // Search conversations
  Future<List<Conversation>> searchConversations(String query) async {
    final response = await _dio.get(
      '/api/v1/chats/search',
      queryParameters: {'q': query},
      options: Options(responseType: ResponseType.bytes),
    );
    return _parseConversationSummaryPayload(
      regular: response.data,
      debugLabel: 'parse_search',
    );
  }
  // dispose() removed – no legacy websocket resources to clean up

  // Helper method to get current weekday name
  // ==================== ADVANCED CHAT FEATURES ====================
  // Chat import/export, bulk operations, and advanced search

  /// Get pinned chats
  Future<List<Conversation>> getPinnedChats() async {
    _traceApi('Fetching pinned chats');
    return _fetchConversationSummaries(
      '/api/v1/chats/pinned',
      debugLabel: 'parse_pinned_chats',
      pinned: true,
    );
  }

  /// Get archived chats
  Future<List<Conversation>> getArchivedChats({int? limit, int? offset}) async {
    _traceApi('Fetching archived chats');
    final queryParams = <String, dynamic>{};
    if (limit != null) queryParams['limit'] = limit;
    if (offset != null) queryParams['offset'] = offset;

    return _fetchConversationSummaries(
      '/api/v1/chats/archived',
      queryParameters: queryParams,
      debugLabel: 'parse_archived_chats',
      archived: true,
    );
  }

  /// Advanced search for chats and messages
  Future<List<Conversation>> searchChats({
    String? query,
    String? userId,
    String? model,
    String? tag,
    String? folderId,
    DateTime? fromDate,
    DateTime? toDate,
    bool? pinned,
    bool? archived,
    int? limit,
    int? offset,
    String? sortBy,
    String? sortOrder,
  }) async {
    _traceApi('Searching chats with query: $query');
    final queryParams = <String, dynamic>{};
    // OpenAPI expects 'text' for this endpoint; keep extras if server tolerates them
    if (query != null) queryParams['text'] = query;
    if (userId != null) queryParams['user_id'] = userId;
    if (model != null) queryParams['model'] = model;
    if (tag != null) queryParams['tag'] = tag;
    if (folderId != null) queryParams['folder_id'] = folderId;
    if (fromDate != null) queryParams['from_date'] = fromDate.toIso8601String();
    if (toDate != null) queryParams['to_date'] = toDate.toIso8601String();
    if (pinned != null) queryParams['pinned'] = pinned;
    if (archived != null) queryParams['archived'] = archived;
    if (limit != null) queryParams['limit'] = limit;
    if (offset != null) queryParams['offset'] = offset;
    if (sortBy != null) queryParams['sort_by'] = sortBy;
    if (sortOrder != null) queryParams['sort_order'] = sortOrder;

    final response = await _dio.get(
      '/api/v1/chats/search',
      queryParameters: queryParams,
      options: Options(responseType: ResponseType.bytes),
    );
    return _parseConversationSummaryPayload(
      regular: response.data,
      debugLabel: 'parse_search_wrapped',
    );
  }

  /// Search within messages content (capability-safe)
  ///
  /// Many OpenWebUI versions do not expose a dedicated messages search endpoint.
  /// We attempt a GET to `/api/v1/chats/messages/search` and gracefully return
  /// an empty list when the endpoint is missing or method is not allowed
  /// (404/405), avoiding noisy errors.
  Future<List<Map<String, dynamic>>> searchMessages({
    required String query,
    String? chatId,
    String? userId,
    String? role, // 'user' or 'assistant'
    DateTime? fromDate,
    DateTime? toDate,
    int? limit,
    int? offset,
  }) async {
    _traceApi('Searching messages with query: $query');

    // Build query parameters; include both 'text' and 'query' for compatibility
    final qp = <String, dynamic>{
      'text': query,
      'query': query,
      'chat_id': ?chatId,
      'user_id': ?userId,
      'role': ?role,
      if (fromDate != null) 'from_date': fromDate.toIso8601String(),
      if (toDate != null) 'to_date': toDate.toIso8601String(),
      'limit': ?limit,
      'offset': ?offset,
    };

    try {
      final response = await _dio.get(
        '/api/v1/chats/messages/search',
        queryParameters: qp,
        // Accept 404/405 to avoid throwing when endpoint is unsupported
        options: Options(
          validateStatus: (code) =>
              code != null && (code < 400 || code == 404 || code == 405),
        ),
      );

      // If not supported, quietly return empty results
      if (response.statusCode == 404 || response.statusCode == 405) {
        _traceApi(
          'messages search endpoint not supported (status: ${response.statusCode})',
        );
        return [];
      }

      final data = response.data;
      if (data is List) {
        return await _normalizeList(data, debugLabel: 'parse_message_search');
      }
      if (data is Map<String, dynamic>) {
        final list = (data['items'] ?? data['results'] ?? data['messages']);
        if (list is List) {
          return await _normalizeList(
            list,
            debugLabel: 'parse_message_search_wrapped',
          );
        }
      }
      return const [];
    } on DioException catch (e) {
      // On any transport or other error, degrade gracefully without surfacing
      _traceApi('messages search request failed gracefully: ${e.type}');
      return const [];
    }
  }

  /// Get chat statistics and analytics
  Future<Map<String, dynamic>> getChatStats({
    String? userId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    _traceApi('Fetching chat statistics');
    final queryParams = <String, dynamic>{};
    if (userId != null) queryParams['user_id'] = userId;
    if (fromDate != null) queryParams['from_date'] = fromDate.toIso8601String();
    if (toDate != null) queryParams['to_date'] = toDate.toIso8601String();

    final response = await _dio.get(
      '/api/v1/chats/stats',
      queryParameters: queryParams,
    );
    return response.data as Map<String, dynamic>;
  }
}
