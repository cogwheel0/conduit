part of 'api_service.dart';

mixin _ChatCompletionsApi on _ApiServiceBase {
  // Send chat completed notification
  // This persists usage data and other message metadata to the server
  /// Notify backend that chat streaming is complete.
  /// This triggers any configured filters/actions on the backend.
  /// Matches OpenWebUI's chatCompletedHandler in Chat.svelte.
  ///
  /// Returns the response body which may contain modified messages from
  /// outlet filters. The caller should merge these back into the local
  /// message state (OpenWebUI does this to apply filter-modified content).
  Future<Map<String, dynamic>?> sendChatCompleted({
    required String chatId,
    required String messageId,
    required List<Map<String, dynamic>> messages,
    required String model,
    Map<String, dynamic>? modelItem,
    String? sessionId,
    List<String>? filterIds,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    // Format messages to match OpenWebUI expected structure exactly
    final formattedMessages = messages.map((msg) {
      final formatted = <String, dynamic>{
        'id': msg['id'],
        'role': msg['role'],
        'content': msg['content'],
        'timestamp':
            msg['timestamp'] ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
      // Include info if present (OpenWebUI sends this)
      if (msg.containsKey('info') && msg['info'] != null) {
        formatted['info'] = msg['info'];
      }
      // Include usage if present (issue #274)
      if (msg.containsKey('usage') && msg['usage'] != null) {
        formatted['usage'] = msg['usage'];
      }
      // Include sources if present
      if (msg.containsKey('sources') && msg['sources'] != null) {
        formatted['sources'] = msg['sources'];
      }
      return formatted;
    }).toList();

    final requestData = <String, dynamic>{
      'model': model,
      'messages': formattedMessages,
      'chat_id': chatId,
      'id': messageId,
      'session_id': ?sessionId,
    };

    // Include filter_ids if provided (for outlet filters)
    if (filterIds != null && filterIds.isNotEmpty) {
      requestData['filter_ids'] = filterIds;
    }

    // Include model_item if available
    if (modelItem != null) {
      requestData['model_item'] = modelItem;
    }

    try {
      final resp = await _dio.post(
        '/api/chat/completed',
        data: requestData,
        options: _withAuthSnapshot(
          Options(
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 10),
          ),
          authSnapshot,
        ),
      );
      if (resp.data is Map<String, dynamic>) {
        return resp.data as Map<String, dynamic>;
      }
      return null;
    } catch (_) {
      // Non-critical - filters/actions may not be configured
      return null;
    }
  }
  // -----------------------------------------------------------------------
  // Transport-aware sendMessageSession
  // -----------------------------------------------------------------------

  /// Posts a chat completion request and classifies the server's response
  /// into a typed [ChatCompletionSession].
  ///
  /// Inspects the actual HTTP response to determine the transport mode
  /// (httpStream, taskSocket, or jsonCompletion).
  Future<ChatCompletionSession> sendMessageSession({
    required List<Map<String, dynamic>> messages,
    required String model,
    String? conversationId,
    String? terminalId,
    List<String>? toolIds,
    List<String>? filterIds,
    List<String>? skillIds,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    bool enableCodeInterpreter = false,
    bool isVoiceMode = false,
    Map<String, dynamic>? modelItem,
    String? sessionIdOverride,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    String? responseMessageId,
    Map<String, dynamic>? userSettings,
    String? reasoningEffort,
    String? parentId,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
  }) async {
    // Generate unique IDs
    final messageId =
        (responseMessageId != null && responseMessageId.isNotEmpty)
        ? responseMessageId
        : const Uuid().v4();
    // Only use the socket session ID when a real socket connection exists.
    // When the socket is disconnected, session_id must be null/absent so the
    // backend falls back to returning SSE directly (httpStream transport)
    // instead of creating an async task that emits socket events to a
    // non-existent session. This mirrors OpenWebUI's frontend which sends
    // `session_id: $socket?.id` (undefined when disconnected).
    final sessionId =
        (sessionIdOverride != null && sessionIdOverride.isNotEmpty)
        ? sessionIdOverride
        : null;
    CancelToken? activeCancelToken;
    Future<void> abort() async {
      final cancelToken = activeCancelToken;
      if (cancelToken != null && !cancelToken.isCancelled) {
        cancelToken.cancel('User cancelled');
      }
    }

    _streamCancelActions[messageId] = abort;
    var legacyPendingTurnPersisted = false;

    Future<void> ensureLegacyPendingTurnPersisted() async {
      if (legacyPendingTurnPersisted ||
          conversationId == null ||
          conversationId.isEmpty ||
          conversationId.startsWith('local:') ||
          userMessage == null ||
          userMessage.isEmpty) {
        return;
      }

      await _persistLegacyPendingTurn(
        conversationId: conversationId,
        assistantMessageId: messageId,
        model: model,
        userMessage: userMessage,
        modelItem: modelItem,
      );
      legacyPendingTurnPersisted = true;
    }

    Future<Response<ResponseBody>> postWithMetadataFormat(
      _ChatRequestMetadataFormat metadataFormat,
    ) async {
      final data = _buildChatCompletionPayload(
        messages: messages,
        model: model,
        messageId: messageId,
        sessionId: sessionId,
        conversationId: conversationId,
        terminalId: terminalId,
        toolIds: toolIds,
        filterIds: filterIds,
        skillIds: skillIds,
        enableWebSearch: enableWebSearch,
        enableImageGeneration: enableImageGeneration,
        enableCodeInterpreter: enableCodeInterpreter,
        isVoiceMode: isVoiceMode,
        modelItem: modelItem,
        toolServers: toolServers,
        backgroundTasks: backgroundTasks,
        userSettings: userSettings,
        reasoningEffort: reasoningEffort,
        parentId: parentId,
        userMessage: userMessage,
        variables: variables,
        files: files,
        metadataFormat: metadataFormat,
      );

      _traceApi(
        'sendMessageSession: posting to /api/chat/completions '
        '(model=$model, sessionId=$sessionId, '
        'metadataFormat=${metadataFormat.name})',
      );

      final cancelToken = CancelToken();
      activeCancelToken = cancelToken;

      return _dio.post<ResponseBody>(
        '/api/chat/completions',
        data: data,
        options: Options(
          responseType: ResponseType.stream,
          // Accept all non-5xx so we can inspect error bodies ourselves.
          validateStatus: (status) => status != null && status < 600,
        ),
        cancelToken: cancelToken,
      );
    }

    var metadataFormat =
        _chatRequestMetadataFormat ?? _ChatRequestMetadataFormat.modernV09;
    if (metadataFormat == _ChatRequestMetadataFormat.legacyPreV09) {
      await ensureLegacyPendingTurnPersisted();
    }
    var resp = await postWithMetadataFormat(metadataFormat);
    var status = resp.statusCode ?? 0;

    // Surface structured errors before transport binding.
    if (status < 200 || status >= 300) {
      final error = await _decodeChatCompletionError(resp);
      final shouldRetryWithLegacy =
          metadataFormat == _ChatRequestMetadataFormat.modernV09 &&
          _isUnsupportedModernChatMetadataError(error);

      if (!shouldRetryWithLegacy) {
        throw Exception('Chat completion failed ($status): $error');
      }

      _traceApi(
        'sendMessageSession: retrying with legacy pre-v0.9 chat metadata '
        'after error: $error',
      );

      metadataFormat = _ChatRequestMetadataFormat.legacyPreV09;
      _chatRequestMetadataFormat = metadataFormat;
      await ensureLegacyPendingTurnPersisted();
      resp = await postWithMetadataFormat(metadataFormat);
      status = resp.statusCode ?? 0;

      if (status < 200 || status >= 300) {
        final retryError = await _decodeChatCompletionError(resp);
        throw Exception('Chat completion failed ($status): $retryError');
      }
    } else {
      _chatRequestMetadataFormat ??= metadataFormat;
    }

    final session = await classifyChatCompletionResponse(
      resp,
      messageId: messageId,
      sessionId: sessionId,
      conversationId: conversationId,
      abort: abort,
    );
    _traceApi(
      'sendMessageSession: transport=${session.transport.name}, '
      'taskId=${session.taskId}, messageId=${session.messageId}',
    );
    return session;
  }
  // -----------------------------------------------------------------------
  // Response classification
  // -----------------------------------------------------------------------

  /// Inspects a streamed [Response] from `/api/chat/completions` and
  /// returns a typed [ChatCompletionSession].
  ///
  /// Classification precedence:
  /// 1. `application/json` content-type → buffer, parse, check `task_id`
  ///    (`null` becomes an empty stream for persisted-chat recovery)
  /// 2. Body sniffing (handles missing / misleading content-type):
  ///    - `data:` prefix → httpStream (with replay stream)
  ///    - Valid JSON → taskSocket or jsonCompletion depending on `task_id`
  /// 3. `text/event-stream` content-type → httpStream
  /// 4. Else → [StateError]
  @visibleForTesting
  Future<ChatCompletionSession> classifyChatCompletionResponse(
    Response<ResponseBody> resp, {
    required String messageId,
    String? sessionId,
    String? conversationId,
    required Future<void> Function() abort,
  }) async {
    final ct = resp.headers.value('content-type') ?? '';
    final isJsonCt = ct.contains('application/json');
    final isEventStreamCt = ct.contains('text/event-stream');

    _traceApi(
      'classifyChatCompletionResponse: content-type=$ct, '
      'status=${resp.statusCode}',
    );

    final body = resp.data;
    if (body == null) {
      DebugLogger.error(
        'chat completion returned an empty body',
        scope: 'api/chat',
        data: {'status': resp.statusCode},
      );
      throw DioException(
        requestOptions: resp.requestOptions,
        response: resp,
        message: 'Empty chat completion response body',
      );
    }
    final bodyStream = body.stream;

    // ------------------------------------------------------------------
    // 1. Explicit application/json → buffer fully and classify
    // ------------------------------------------------------------------
    if (isJsonCt) {
      final json = await _requireJsonMapOrNull(bodyStream);
      if (json == null) {
        return _recoverJsonNullChatCompletion(
          messageId: messageId,
          sessionId: sessionId,
          conversationId: conversationId,
          abort: abort,
        );
      }
      return _classifyJsonBody(
        json,
        messageId: messageId,
        sessionId: sessionId,
        conversationId: conversationId,
        abort: abort,
      );
    }

    // ------------------------------------------------------------------
    // 2. Sniff the body (handles missing or misleading headers)
    // ------------------------------------------------------------------
    final sniffResult = await _sniffChatCompletionBody(bodyStream);

    switch (sniffResult) {
      case _SniffSse(:final buffered, :final rest):
        _traceApi('classifyChatCompletionResponse → httpStream (body sniff)');
        return ChatCompletionSession.httpStream(
          messageId: messageId,
          sessionId: sessionId,
          conversationId: conversationId,
          byteStream: _replayStream(buffered, rest),
          abort: abort,
        );

      case _SniffJson(:final json):
        if (json == null) {
          return _recoverJsonNullChatCompletion(
            messageId: messageId,
            sessionId: sessionId,
            conversationId: conversationId,
            abort: abort,
          );
        }
        return _classifyJsonBody(
          json,
          messageId: messageId,
          sessionId: sessionId,
          conversationId: conversationId,
          abort: abort,
        );
    }

    // ------------------------------------------------------------------
    // 3. Fall back to content-type header
    // ------------------------------------------------------------------
    // ignore: dead_code
    if (isEventStreamCt) {
      _traceApi('classifyChatCompletionResponse → httpStream (content-type)');
      return ChatCompletionSession.httpStream(
        messageId: messageId,
        sessionId: sessionId,
        conversationId: conversationId,
        byteStream: bodyStream,
        abort: abort,
      );
    }

    throw StateError(
      'Unable to classify chat completion response '
      '(content-type=$ct)',
    );
  }
  // -----------------------------------------------------------------------
  // @visibleForTesting helpers
  // -----------------------------------------------------------------------

  /// Exposes [_buildChatCompletionPayload] for unit tests.
  @visibleForTesting
  Map<String, dynamic> buildChatCompletionPayloadForTest({
    required List<Map<String, dynamic>> messages,
    required String model,
    required String messageId,
    required String sessionId,
    String? conversationId,
    String? terminalId,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    bool enableCodeInterpreter = false,
    bool isVoiceMode = false,
    Map<String, dynamic>? modelItem,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    Map<String, dynamic>? userSettings,
    String? reasoningEffort,
    String? parentId,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
    bool useLegacyChatMetadata = false,
  }) {
    return _buildChatCompletionPayload(
      messages: messages,
      model: model,
      messageId: messageId,
      sessionId: sessionId,
      conversationId: conversationId,
      terminalId: terminalId,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
      enableCodeInterpreter: enableCodeInterpreter,
      isVoiceMode: isVoiceMode,
      modelItem: modelItem,
      toolServers: toolServers,
      backgroundTasks: backgroundTasks,
      userSettings: userSettings,
      reasoningEffort: reasoningEffort,
      parentId: parentId,
      userMessage: userMessage,
      variables: variables,
      files: files,
      metadataFormat: useLegacyChatMetadata
          ? _ChatRequestMetadataFormat.legacyPreV09
          : _ChatRequestMetadataFormat.modernV09,
    );
  }

  /// Registers a cancel action for testing the widened cancel map.
  @visibleForTesting
  void registerLegacyCancelActionForTest(
    String messageId,
    Future<void> Function() action,
  ) {
    _streamCancelActions[messageId] = action;
  }

  // === Tasks control (parity with Web client) ===
  Future<void> stopTask(String taskId) async {
    try {
      await _dio.post('/api/tasks/stop/$taskId');
    } catch (e) {
      rethrow;
    }
  }

  Future<void> stopTasksByChat(String chatId) async {
    try {
      final encodedChatId = Uri.encodeComponent(chatId);
      await _dio.post('/api/tasks/chat/$encodedChatId/stop');
    } catch (e) {
      rethrow;
    }
  }

  Future<List<String>> getTaskIdsByChat(String chatId) async {
    try {
      final resp = await _dio.get('/api/tasks/chat/$chatId');
      final data = resp.data;
      if (data is Map && data['task_ids'] is List) {
        return (data['task_ids'] as List).map((e) => e.toString()).toList();
      }
      return const [];
    } catch (e) {
      rethrow;
    }
  }

  Future<List<String>> resolveChatMessageToolCall({
    required String chatId,
    required String messageId,
    required String callId,
    required OpenWebUiToolCallAction action,
    Map<String, dynamic>? answers,
  }) async {
    final response = await _dio.post(
      '/api/v1/chats/${Uri.encodeComponent(chatId)}/messages/'
      '${Uri.encodeComponent(messageId)}/resolve',
      data: <String, dynamic>{
        'call_id': callId,
        'action': action.name,
        if (action == OpenWebUiToolCallAction.answer) 'answers': answers,
      },
    );
    final data = response.data;
    if (data is! Map) return const <String>[];
    final rawTaskIds = data['task_ids'];
    final taskIds = rawTaskIds is List
        ? rawTaskIds
              .map((value) => value?.toString().trim() ?? '')
              .where((value) => value.isNotEmpty)
        : data['task_id'] == null
        ? const Iterable<String>.empty()
        : <String>[data['task_id'].toString().trim()]
              .where((value) => value.isNotEmpty);
    return taskIds.toSet().toList(growable: false);
  }

  /// POST `/api/v1/tasks/active/chats` `{chat_ids: [...]}` → `{active_chat_ids: [...]}`.
  ///
  /// Bulk query for which of [chatIds] currently have an active server task.
  /// Open WebUI through 0.10 provides the dedicated task endpoint; 0.11 puts
  /// the same state on chat-list rows. A 404 or 405 permanently selects that
  /// list fallback for this API-service instance.
  Future<Set<String>> checkActiveChats(List<String> chatIds) async {
    if (chatIds.isEmpty) {
      return <String>{};
    }
    if (_activeChatsEndpointUnsupported) {
      return _checkActiveChatsFromLists(chatIds);
    }
    try {
      final resp = await _dio.post(
        '/api/v1/tasks/active/chats',
        data: {'chat_ids': chatIds},
      );
      final data = resp.data;
      if (data is Map && data['active_chat_ids'] is List) {
        return (data['active_chat_ids'] as List)
            .map((e) => e.toString())
            .toSet();
      }
      return <String>{};
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode;
      if (statusCode == 404 || statusCode == 405) {
        _activeChatsEndpointUnsupported = true;
        DebugLogger.log(
          'active-chats endpoint unsupported; using chat-list state',
          scope: 'api/tasks',
          data: {'status': statusCode},
        );
        return _checkActiveChatsFromLists(chatIds);
      }
      rethrow;
    }
  }

  // Cancel an active streaming message by its messageId (client-side abort)
  void cancelStreamingMessage(String messageId) {
    try {
      final action = _streamCancelActions.remove(messageId);
      if (action != null) {
        action();
      }
    } catch (_) {}
  }

  /// Clears the cancel action for a message when streaming completes normally.
  /// Called by streaming_helper when finishStreaming is invoked.
  void clearStreamCancelToken(String messageId) {
    _streamCancelActions.remove(messageId);
  }
}
