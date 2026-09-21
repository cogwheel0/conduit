part of 'api_service.dart';

mixin _ChatsApi on _ApiServiceBase {
  // Parse OpenWebUI chat format to our Conversation format
  Future<Conversation> getConversation(String id) async {
    DebugLogger.log('fetch', scope: 'api/chat', data: {'id': id});
    final response = await _dio.get(
      '/api/v1/chats/$id',
      options: Options(responseType: ResponseType.bytes),
    );

    DebugLogger.log('fetch-ok', scope: 'api/chat');

    return _parseConversationPayload(
      response.data,
      debugLabel: 'parse_conversation_full',
    );
  }

  // Create new conversation using OpenWebUI API
  Future<Conversation> createConversation({
    required String title,
    required List<ChatMessage> messages,
    String? model,
    String? systemPrompt,
    String? folderId,
  }) async {
    _traceApi('Creating new conversation on OpenWebUI server');
    _traceApi('Title: $title, Messages: ${messages.length}');

    // Build messages with parent-child relationships
    final Map<String, dynamic> messagesMap = {};
    final List<Map<String, dynamic>> messagesArray = [];
    String? currentId;
    String? previousId;
    String? lastUserId;
    for (final msg in messages) {
      final messageId = msg.id;
      final sanitizedEmbeds = _sanitizeEmbedsForWebUI(msg.embeds);

      // Choose parent id (branch assistants from last user)
      final parentId = msg.role == 'assistant'
          ? (lastUserId ?? previousId)
          : previousId;

      // Build message for history.messages map
      messagesMap[messageId] = {
        'id': messageId,
        'parentId': parentId,
        'childrenIds': [],
        'role': msg.role,
        'content': msg.content,
        'timestamp': msg.timestamp.millisecondsSinceEpoch ~/ 1000,
        // Assistant message fields
        if (msg.role == 'assistant' && msg.model != null) 'model': msg.model,
        if (msg.role == 'assistant' && msg.model != null)
          'modelName': msg.model,
        if (msg.role == 'assistant') 'modelIdx': 0,
        if (assistantMessageResponseCompleted(msg)) 'done': true,
        // User message fields
        if (msg.role == 'user' && model != null) 'models': [model],
        if (msg.attachmentIds != null && msg.attachmentIds!.isNotEmpty)
          'attachment_ids': List<String>.from(msg.attachmentIds!),
        if (sanitizeFilesForWebUi(msg.files) != null)
          'files': sanitizeFilesForWebUi(msg.files),
        'embeds': ?sanitizedEmbeds,
        // Assistant message extended fields
        if (msg.statusHistory.isNotEmpty)
          'statusHistory': msg.statusHistory.map((s) => s.toJson()).toList(),
        if (msg.followUps.isNotEmpty)
          'followUps': List<String>.from(msg.followUps),
        if (msg.codeExecutions.isNotEmpty)
          'code_executions': convertCodeExecutionsToOpenWebUIFormat(
            msg.codeExecutions,
          ),
        if (msg.sources.isNotEmpty)
          'sources': convertSourcesToOpenWebUIFormat(msg.sources),
        if (msg.usage != null) 'usage': msg.usage,
        // Preserve error field for OpenWebUI compatibility
        if (msg.error != null) 'error': msg.error!.toJson(),
      };

      // Update parent's childrenIds if there's a previous message
      if (parentId != null && messagesMap.containsKey(parentId)) {
        (messagesMap[parentId]['childrenIds'] as List).add(messageId);
      }

      // Build message for messages array
      messagesArray.add({
        'id': messageId,
        'parentId': parentId,
        'childrenIds': [],
        'role': msg.role,
        'content': msg.content,
        'timestamp': msg.timestamp.millisecondsSinceEpoch ~/ 1000,
        // Assistant message fields
        if (msg.role == 'assistant' && msg.model != null) 'model': msg.model,
        if (msg.role == 'assistant' && msg.model != null)
          'modelName': msg.model,
        if (msg.role == 'assistant') 'modelIdx': 0,
        if (assistantMessageResponseCompleted(msg)) 'done': true,
        // User message fields
        if (msg.role == 'user' && model != null) 'models': [model],
        if (msg.attachmentIds != null && msg.attachmentIds!.isNotEmpty)
          'attachment_ids': List<String>.from(msg.attachmentIds!),
        if (sanitizeFilesForWebUi(msg.files) != null)
          'files': sanitizeFilesForWebUi(msg.files),
        'embeds': ?sanitizedEmbeds,
        // Assistant message extended fields
        if (msg.statusHistory.isNotEmpty)
          'statusHistory': msg.statusHistory.map((s) => s.toJson()).toList(),
        if (msg.followUps.isNotEmpty)
          'followUps': List<String>.from(msg.followUps),
        if (msg.codeExecutions.isNotEmpty)
          'code_executions': convertCodeExecutionsToOpenWebUIFormat(
            msg.codeExecutions,
          ),
        if (msg.sources.isNotEmpty)
          'sources': convertSourcesToOpenWebUIFormat(msg.sources),
        if (msg.usage != null) 'usage': msg.usage,
        // Preserve error field for OpenWebUI compatibility
        if (msg.error != null) 'error': msg.error!.toJson(),
      });

      previousId = messageId;
      currentId = messageId;
      if (msg.role == 'user') {
        lastUserId = messageId;
      }
    }

    // Create the chat data structure matching OpenWebUI format exactly
    final chatData = {
      'chat': {
        'id': '',
        'title': title,
        'models': model != null ? [model] : [],
        if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
          'system': systemPrompt,
        'params': {},
        'history': {'messages': messagesMap, 'currentId': ?currentId},
        'messages': messagesArray,
        'tags': [],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      'folder_id': folderId,
    };

    _traceApi('Sending chat data with proper parent-child structure');
    _traceApi('Request data: $chatData');

    final response = await _dio.post(
      '/api/v1/chats/new',
      data: chatData,
      options: Options(responseType: ResponseType.bytes),
    );

    DebugLogger.log(
      'create-status',
      scope: 'api/conversation',
      data: {'code': response.statusCode},
    );
    DebugLogger.log('create-ok', scope: 'api/conversation');

    return _parseConversationPayload(
      response.data,
      debugLabel: 'parse_conversation_full',
    );
  }

  /// Deletes one message from the current server-side chat history.
  Future<void> deleteConversationMessage(
    String conversationId,
    String messageId,
  ) async {
    _traceApi('Deleting message $messageId from chat $conversationId');
    try {
      await _dio.delete('/api/v1/chats/$conversationId/messages/$messageId');
    } on DioException catch (error) {
      if (!_shouldFallbackToLegacyMessageDelete(error)) {
        rethrow;
      }
      DebugLogger.log(
        'delete-message-legacy-fallback',
        scope: 'api/conversation',
        data: {
          'chatId': conversationId,
          'messageId': messageId,
          'status': error.response?.statusCode,
        },
      );
      await _deleteConversationMessageByHistoryRewrite(
        conversationId,
        messageId,
      );
    }
  }

  Future<void> updateConversation(
    String id, {
    String? title,
    String? systemPrompt,
  }) async {
    // OpenWebUI expects POST to /api/v1/chats/{id} with ChatForm { chat: {...} }
    final chatPayload = <String, dynamic>{
      'title': ?title,
      'system': ?systemPrompt,
    };
    await _dio.post('/api/v1/chats/$id', data: {'chat': chatPayload});
  }

  Future<void> deleteConversation(String id) async {
    // Deleting an already-absent chat is successful from the caller's point
    // of view. This also closes the race where another Open WebUI client
    // deletes the chat after it was rendered locally but before this request.
    await deleteChatRaw(id);
  }

  // Pin/Unpin conversation
  Future<void> pinConversation(String id, bool pinned) async {
    _traceApi('${pinned ? 'Pinning' : 'Unpinning'} conversation: $id');
    await _setConversationToggle(
      id: id,
      field: 'pinned',
      endpoint: '/api/v1/chats/$id/pin',
      desired: pinned,
    );
  }

  // Archive/Unarchive conversation
  Future<void> archiveConversation(String id, bool archived) async {
    _traceApi('${archived ? 'Archiving' : 'Unarchiving'} conversation: $id');
    await _setConversationToggle(
      id: id,
      field: 'archived',
      endpoint: '/api/v1/chats/$id/archive',
      desired: archived,
    );
  }

  // Share conversation
  Future<String?> shareConversation(String id) async {
    _traceApi('Sharing conversation: $id');
    final response = await _dio.post('/api/v1/chats/$id/share');
    final data = _coerceJsonMap(response.data);
    if (data == null) {
      DebugLogger.error(
        'share-format',
        scope: 'api/conversation',
        data: {'type': response.data.runtimeType},
      );
      return null;
    }
    final shareId = data['share_id'];
    if (shareId == null || shareId is String) {
      return shareId;
    }
    DebugLogger.error(
      'share-id-format',
      scope: 'api/conversation',
      data: {'type': shareId.runtimeType},
    );
    return null;
  }

  Future<void> deleteSharedConversation(String id) async {
    _traceApi('Deleting shared conversation link: $id');
    await _dio.delete('/api/v1/chats/$id/share');
  }

  // Clone conversation
  Future<Conversation> cloneConversation(String id) async {
    _traceApi('Cloning conversation: $id');
    final response = await _dio.post(
      '/api/v1/chats/$id/clone',
      data: const <String, dynamic>{},
      options: Options(responseType: ResponseType.bytes),
    );
    return _parseConversationPayload(
      response.data,
      debugLabel: 'parse_conversation_full',
    );
  }
}
