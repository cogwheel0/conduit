part of 'api_service.dart';

mixin _ChatsRawApi on _ApiServiceBase {
  // ---- CDT-RFC-001 Phase 1: raw sync-engine reads ----------------------
  // These exist because every legacy chat method parses to `Conversation`
  // and discards the blob/epoch ints the sync engine needs. All three are
  // read-only GETs through the existing Dio instance, so ApiAuthInterceptor
  // bearer/custom-header behavior applies unchanged.
  //
  // TODO(CDT-RFC-001 §7.2, §3.iii): Phase 2 push needs a generic
  // `updateChat(id, blob)` that always sends the complete `rowsToBlob`
  // reconstruction, never a partial dict (the server shallow-merges
  // top-level keys).

  /// GET `/api/v1/chats/?page={page}&include_pinned={..}&include_folders={..}`
  ///
  /// Raw `ChatTitleIdResponse` maps: `{id, title, updated_at, created_at,
  /// last_read_at}`. No model parsing; epoch-second ints preserved. Server
  /// page size is 60 (`routers/chats.py` `get_session_user_chat_list`,
  /// `limit = 60`); the legacy `expectedPageSize: 50` path above is
  /// untouched (it goes dead in Stage C).
  Future<List<Map<String, dynamic>>> getChatListPageRaw({
    required int page,
    bool includePinned = true,
    bool includeFolders = true,
  }) async {
    final response = await _dio.get(
      '/api/v1/chats/',
      queryParameters: {
        'page': page,
        'include_pinned': includePinned,
        'include_folders': includeFolders,
      },
    );
    return _coerceRawMapList(response.data);
  }

  /// GET `/api/v1/chats/archived?page={page}&order_by=updated_at&direction=desc`
  ///
  /// Raw `ChatTitleIdResponse` maps; fixed server limit 60
  /// (`get_archived_session_user_chat_list`). The existing
  /// [getArchivedChats] sends limit/offset params the server ignores; it is
  /// left alone and goes dead in Stage C.
  Future<List<Map<String, dynamic>>> getArchivedChatListPageRaw({
    required int page,
  }) async {
    final response = await _dio.get(
      '/api/v1/chats/archived',
      queryParameters: {
        'page': page,
        'order_by': 'updated_at',
        'direction': 'desc',
      },
    );
    return _coerceRawMapList(response.data);
  }

  /// GET `/api/v1/chats/pinned` — every chat the account has pinned and not
  /// archived, as raw `ChatTitleIdResponse` maps, in one unpaged answer
  /// (`get_pinned_chats_by_user_id`).
  Future<List<Map<String, dynamic>>> getPinnedChatListRaw() async {
    final response = await _dio.get('/api/v1/chats/pinned');
    return _coerceRawMapList(response.data);
  }

  /// GET `/api/v1/chats/archived/count` — how many chats the account has
  /// archived; null when the answer is not a number.
  Future<int?> getArchivedChatCountRaw() async {
    final response = await _dio.get('/api/v1/chats/archived/count');
    final data = response.data;
    return data is num ? data.toInt() : null;
  }

  /// GET `/api/v1/chats/{id}` — the raw `ChatResponse` map (id, user_id,
  /// title, chat, updated_at, created_at, share_id, archived, pinned, meta,
  /// folder_id).
  ///
  /// Returns null on 404; malformed 2xx bodies throw. NOTE: the vendored route
  /// signals a missing/unowned chat with HTTP 401 (`ERROR_MESSAGES.NOT_FOUND`),
  /// which intentionally surfaces here as an error so an expired token can
  /// never read as a mass delete; Phase 3 deletion reconcile handles 404/401
  /// explicitly. Large payloads are decoded off the UI isolate, mirroring
  /// the bytes->worker path of [_parseConversationPayload], but stop at the
  /// decoded map — no `Conversation` parsing.
  ///
  /// A caller that already authorized this read for one account passes the
  /// [authSnapshot] it captured, so a token change that lands before the
  /// request is sent cannot read another account's chat with the new bearer.
  @override
  Future<Map<String, dynamic>?> getChatRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    DebugLogger.log('fetch-raw', scope: 'api/chat', data: {'id': id});
    try {
      final response = await _dio.get(
        '/api/v1/chats/$id',
        options: _withAuthSnapshot(
          Options(responseType: ResponseType.bytes),
          authSnapshot,
        ),
      );
      return await _decodeChatEnvelopeResponse(response.data, 'getChatRaw $id');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}/fork` body `{message_id: messageId}` — the raw
  /// `ChatResponse` of the new chat, which stops at [messageId] while the source
  /// chat stays as it was.
  ///
  /// Sent exactly once, with the [authSnapshot] the caller captured, and with no
  /// fallback to a whole-chat clone. Every HTTP failure is rethrown for the
  /// caller to classify (403 no `chat.import`, 401 not the owner or gone, 404
  /// no such message, 409 a response is still running). A 2xx without a chat
  /// body throws, since the route may answer `null`.
  Future<Map<String, dynamic>> forkChatRaw(
    String id,
    String messageId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    DebugLogger.log('fork-raw', scope: 'api/chat', data: {'id': id});
    final response = await _dio.post(
      '/api/v1/chats/$id/fork',
      data: <String, dynamic>{'message_id': messageId},
      options: _withAuthSnapshot(
        Options(responseType: ResponseType.bytes),
        authSnapshot,
      ),
    );
    final map = await _decodeChatEnvelopeResponse(
      response.data,
      'forkChatRaw $id',
    );
    if (map['id'] is! String || (map['id'] as String).isEmpty) {
      throw FormatException('forkChatRaw $id: response without a chat id');
    }
    return map;
  }

  /// Decodes a `ChatResponse` body, off the UI isolate when it is large. Throws
  /// [FormatException] unless the body is a JSON object.
  Future<Map<String, dynamic>> _decodeChatEnvelopeResponse(
    Object? data,
    String label,
  ) async {
    final bytes = data is Uint8List
        ? data
        : (data is List<int> ? Uint8List.fromList(data) : null);
    if (bytes == null) {
      // Defensive: some adapters may have decoded already.
      return _requireResponseMap(data, label);
    }
    final Map<String, dynamic>? map =
        bytes.lengthInBytes >= _conversationWorkerByteThreshold
        ? await _workerManager.schedule<Uint8List, Map<String, dynamic>?>(
            decodeChatResponseEnvelopeWorker,
            bytes,
            debugLabel: 'decode_chat_raw',
          )
        : decodeChatResponseEnvelopeWorker(bytes);
    if (map == null) {
      throw FormatException('$label: expected JSON object response');
    }
    return map;
  }
  // ===== Phase 2 sync write seams (CDT-RFC-001 §7.2/§7.4) =====
  //
  // These accept a prebuilt `rowsToBlob` blob and return the decoded
  // `ChatResponse` map verbatim. They deliberately do NOT reuse
  // `createConversation` (which builds its own blob from `ChatMessage`) nor
  // `updateConversation` (which sends a partial `{title, system}` dict — the
  // §3.iii shallow-merge hazard).

  /// Whether a 401 or 403 refused the session still current. One that
  /// refused [authSnapshot]'s session after another replaced it says nothing
  /// about the current one, so it is not terminal: the write goes again.
  bool _refusedCurrentSession(ApiAuthSnapshot? authSnapshot) =>
      authSnapshot == null || authSnapshotIsCurrent(authSnapshot);

  /// POST `/api/v1/chats/new` with the COMPLETE blob; returns the parsed
  /// `ChatResponse` map (the server mints `id`).
  Future<Map<String, dynamic>> createChatRaw(
    Map<String, dynamic> chatBlob, {
    String? folderId,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/chats/new',
        data: {'chat': chatBlob, 'folder_id': ?folderId},
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      return _requireResponseMap(response.data, 'createChatRaw');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'createChat forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}` with the COMPLETE blob. Returns the parsed
  /// `ChatResponse` map; throws [SyncTerminalException] on 401/403.
  /// NOTE: the vendored `update_chat_by_id` route returns 401 (not 404) for a
  /// missing/unowned chat, so a server-side delete surfaces as
  /// [SyncTerminalException], not null; the 404->null branch is defensive only.
  Future<Map<String, dynamic>?> updateChatRaw(
    String id,
    Map<String, dynamic> chat, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/chats/$id',
        data: {'chat': chat},
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      return _requireResponseMap(response.data, 'updateChatRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'updateChat $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// GET `/api/tasks/chat/{id}`: the tasks the session's account runs in
  /// chat [chatId], as Open WebUI lists them (only that account's). Throws
  /// [FormatException] for an answer that is not such a list, and
  /// [SyncTerminalException] for 401/403.
  Future<List<String>> getChatTaskIdsRaw(
    String chatId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      final response = await _dio.get(
        '/api/tasks/chat/${Uri.encodeComponent(chatId)}',
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      return _chatTaskIds(response.data, chatId);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'getChatTaskIds $chatId forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/tasks/chat/{id}/stop`. With none of the account's tasks
  /// running there, Open WebUI marks each of the account's answers in the
  /// chat that it holds as not done as done, keeping the text it stored.
  /// 401/403 -> [SyncTerminalException].
  Future<void> stopChatTasksRaw(
    String chatId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      await _dio.post(
        '/api/tasks/chat/${Uri.encodeComponent(chatId)}/stop',
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'stopChatTasks $chatId forbidden',
        );
      }
      rethrow;
    }
  }

  /// DELETE `/api/v1/chats/{id}`. `true` on success; 404 -> `false` (already
  /// gone, no throw); 401/403 -> [SyncTerminalException].
  @override
  Future<bool> deleteChatRaw(String id, {ApiAuthSnapshot? authSnapshot}) async {
    try {
      await _dio.delete(
        '/api/v1/chats/$id',
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return false;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'deleteChat $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// GET `/api/v1/chats/{id}/pinned` -> bool (false on a null/absent body).
  Future<bool> getChatPinnedRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      final response = await _dio.get(
        '/api/v1/chats/$id/pinned',
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      return response.data == true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return false;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'getChatPinned $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}/pin` — low-level stateless toggle primitive.
  ///
  /// Do not enqueue or retry this operation directly. Sync write paths must call
  /// desired-state reconcilers that probe before toggling and confirm after,
  /// because retrying this primitive alone can double-flip.
  ///
  /// Returns the parsed `ChatResponse`; null on 404.
  Future<Map<String, dynamic>?> togglePinRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/chats/$id/pin',
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      return _requireResponseMap(response.data, 'togglePinRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'pinChat $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}/archive` — low-level stateless toggle primitive.
  ///
  /// Do not enqueue or retry this operation directly. Sync write paths must call
  /// desired-state reconcilers that probe before toggling and confirm after,
  /// because retrying this primitive alone can double-flip.
  ///
  /// Returns the parsed `ChatResponse`; null on 404.
  Future<Map<String, dynamic>?> toggleArchiveRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/chats/$id/archive',
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      return _requireResponseMap(response.data, 'toggleArchiveRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'archiveChat $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// POST `/api/v1/chats/{id}/folder` body `{folder_id: folderId}`. Returns
  /// the parsed `ChatResponse`; null on 404.
  Future<Map<String, dynamic>?> moveChatToFolderRaw(
    String id,
    String? folderId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    try {
      final response = await _dio.post(
        '/api/v1/chats/$id/folder',
        data: {'folder_id': folderId},
        options: _withAuthSnapshot(Options(), authSnapshot),
      );
      return _requireResponseMap(response.data, 'moveChatToFolderRaw $id');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if ((code == 401 || code == 403) &&
          _refusedCurrentSession(authSnapshot)) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'moveChatToFolder $id forbidden',
        );
      }
      rethrow;
    }
  }

  /// DELETE `/api/v1/folders/{id}?delete_contents=<flag>`.
  ///
  /// Distinct from [deleteFolder] (which omits the param and gets the
  /// DESTRUCTIVE server default `true`). Sync-driven deletes pass `false` so
  /// contained chats are re-parented to root, not deleted (verified
  /// `routers/folders.py:delete_folder_by_id`).
  /// Returns `true` on success; `false` on 404 (already gone); 401/403 ->
  /// [SyncTerminalException].
  Future<bool> deleteFolderRaw(String id, {bool deleteContents = false}) async {
    try {
      await _dio.delete(
        '/api/v1/folders/$id',
        queryParameters: {'delete_contents': deleteContents},
      );
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return false;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'deleteFolder $id forbidden',
        );
      }
      rethrow;
    }
  }
}

/// The task ids in [data], a chat's task list as Open WebUI answers it
/// (`{"task_ids": [...]}`). Anything else is no answer: an empty list read
/// from it would let the chat's stop be asked over a task still running.
List<String> _chatTaskIds(Object? data, String chatId) {
  final ids = data is Map ? data['task_ids'] : null;
  if (ids is! List) {
    throw FormatException('no task list for chat $chatId');
  }
  return <String>[for (final id in ids) id.toString()];
}
