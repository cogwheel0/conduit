part of 'api_service.dart';

/// Open WebUI's account-wide chat routes behind Settings > Data controls: the
/// library export and import, and archive, unarchive, unshare and delete for
/// every chat the account owns.
///
/// Each request is bound to the [ApiAuthSnapshot] the caller captured, so a
/// credential change that lands after the user confirmed cannot redirect it to
/// another account. None of them is retried here: an import sent twice would
/// duplicate every chat, and a bulk change whose answer was lost is for the
/// user to see and repeat.
mixin _ChatDataControlsApi on _ApiServiceBase {
  /// Whole-library operations on a large account outlast the default 30 second
  /// receive timeout, which would report a finished import as a failure.
  static const Duration _bulkReceiveTimeout = Duration(minutes: 10);

  /// GET `/api/v1/chats/all`: every chat the account owns as newline-delimited
  /// JSON, one `ChatResponse` per line, in chunked UTF-8. The bytes are handed
  /// over as they arrive; nothing is buffered or parsed here.
  Future<Stream<List<int>>> openChatLibraryExport({
    ApiAuthSnapshot? authSnapshot,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get<ResponseBody>(
      '/api/v1/chats/all',
      options: _withAuthSnapshot(
        Options(
          responseType: ResponseType.stream,
          headers: const <String, dynamic>{'Accept': 'application/x-ndjson'},
          receiveTimeout: const Duration(minutes: 2),
        ),
        authSnapshot,
      ),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (body == null) {
      throw const FormatException('chat export: response without a body');
    }
    return body.stream;
  }

  /// POST `/api/v1/chats/import` with [body], the prepared `{"chats": [...]}`
  /// request, sent as given and exactly once. Returns the chats the server
  /// created, as raw `ChatResponse` maps carrying their new server ids.
  ///
  /// 403 means the account lacks `chat.import`. A failure with no answer leaves
  /// it unknown whether the server imported anything; the caller must not send
  /// the same body again on its own.
  Future<List<Map<String, dynamic>>> importChatsRaw(
    Uint8List body, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    final response = await _dio.post(
      '/api/v1/chats/import',
      data: body,
      options: _withAuthSnapshot(
        Options(
          contentType: Headers.jsonContentType,
          responseType: ResponseType.bytes,
          headers: const <String, dynamic>{'Accept': 'application/json'},
          receiveTimeout: _bulkReceiveTimeout,
        ),
        authSnapshot,
      ),
    );
    final data = response.data;
    final bytes = data is Uint8List
        ? data
        : (data is List<int> ? Uint8List.fromList(data) : null);
    final rows = bytes == null
        ? null
        : bytes.lengthInBytes >= _conversationWorkerByteThreshold
        ? await _workerManager.schedule<Uint8List, List<Map<String, dynamic>>?>(
            decodeChatResponseListWorker,
            bytes,
            debugLabel: 'decode_chat_import',
          )
        : decodeChatResponseListWorker(bytes);
    if (rows == null) {
      throw const FormatException('importChats: expected a JSON array');
    }
    return rows;
  }

  /// POST `/api/v1/chats/archive/all`.
  Future<bool> archiveAllChatsRaw({ApiAuthSnapshot? authSnapshot}) =>
      _bulkChatRequest('POST', '/api/v1/chats/archive/all', authSnapshot);

  /// POST `/api/v1/chats/unarchive/all`.
  Future<bool> unarchiveAllChatsRaw({ApiAuthSnapshot? authSnapshot}) =>
      _bulkChatRequest('POST', '/api/v1/chats/unarchive/all', authSnapshot);

  /// DELETE `/api/v1/chats/share/all`: removes every share link the account
  /// made. The chats themselves stay.
  Future<bool> unshareAllChatsRaw({ApiAuthSnapshot? authSnapshot}) =>
      _bulkChatRequest('DELETE', '/api/v1/chats/share/all', authSnapshot);

  /// DELETE `/api/v1/chats/`: deletes every chat the account owns, which the
  /// server cannot restore. 401 means the account lacks `chat.delete`.
  Future<bool> deleteAllChatsRaw({ApiAuthSnapshot? authSnapshot}) =>
      _bulkChatRequest('DELETE', '/api/v1/chats/', authSnapshot);

  /// The four bulk routes answer a JSON boolean, and answer `false` with a 200
  /// when the change failed inside the server. Only a literal `true` is
  /// success.
  Future<bool> _bulkChatRequest(
    String method,
    String path,
    ApiAuthSnapshot? authSnapshot,
  ) async {
    final response = await _dio.request<Object?>(
      path,
      options: _withAuthSnapshot(
        Options(
          method: method,
          headers: const <String, dynamic>{'Accept': 'application/json'},
          receiveTimeout: _bulkReceiveTimeout,
        ),
        authSnapshot,
      ),
    );
    return response.data == true;
  }
}
