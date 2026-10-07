part of 'api_service.dart';

/// Access-grant routes of the three resources an account can share from the
/// everyday UI: a chat, a folder and a note.
///
/// Each resource has its own route and its own caller rule on the server, so
/// they are separate methods rather than one generic one. A grant is
/// `{principal_type, principal_id, permission}`; reading and writing are
/// separate rows. Every method takes the [ApiAuthSnapshot] captured when the
/// sharing sheet opened: the request is cancelled instead of sent if the
/// account changed since, even though the [ApiService] instance is shared.
mixin _ResourceGrantsApi on _ApiServiceBase {
  /// GET `/api/v1/chats/shared/{id}/access`.
  ///
  /// [originalChatId] is the chat's own id. The public link's `share_id` names
  /// a snapshot and is the wrong key here: the route looks up an owned chat.
  Future<List<Map<String, dynamic>>> getChatAccessGrants(
    String originalChatId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching chat access grants: $originalChatId');
    final response = await _dio.get(
      '/api/v1/chats/shared/$originalChatId/access',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _grantRows(response.data, 'getChatAccessGrants');
  }

  /// POST `/api/v1/chats/shared/{id}/access/update`, body `{access_grants}`.
  Future<void> updateChatAccessGrants(
    String originalChatId,
    List<Map<String, dynamic>> grants, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Updating chat access grants: $originalChatId');
    await _dio.post(
      '/api/v1/chats/shared/$originalChatId/access/update',
      data: <String, dynamic>{'access_grants': grants},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  /// GET `/api/v1/folders/{id}`: the folder with its `access_grants` and the
  /// caller's `write_access`.
  Future<Map<String, dynamic>> getFolderAccess(
    String folderId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching folder access: $folderId');
    final response = await _dio.get(
      '/api/v1/folders/$folderId',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _requireResponseMap(response.data, 'getFolderAccess $folderId');
  }

  /// POST `/api/v1/folders/{id}/access/update`, body `{access_grants}`.
  Future<void> updateFolderAccessGrants(
    String folderId,
    List<Map<String, dynamic>> grants, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Updating folder access grants: $folderId');
    await _dio.post(
      '/api/v1/folders/$folderId/access/update',
      data: <String, dynamic>{'access_grants': grants},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  /// GET `/api/v1/notes/{id}`, pinned to the opening session. The detail is
  /// the only response that carries `write_access`, and a revoked recipient
  /// gets a 403 here that callers must not read as a missing note.
  Future<Map<String, dynamic>> getNoteForSession(
    String noteId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Fetching note access: $noteId');
    final response = await _dio.get(
      '/api/v1/notes/$noteId',
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
    return _requireResponseMap(response.data, 'getNoteForSession $noteId');
  }

  /// POST `/api/v1/notes/{id}/access/update`, body `{access_grants}`. Allowed
  /// for the owner, an admin and a write recipient, so it works for a note the
  /// account did not create. The response omits `write_access`.
  Future<void> updateNoteAccessGrants(
    String noteId,
    List<Map<String, dynamic>> grants, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _traceApi('Updating note access grants: $noteId');
    await _dio.post(
      '/api/v1/notes/$noteId/access/update',
      data: <String, dynamic>{'access_grants': grants},
      options: _withAuthSnapshot(Options(), authSnapshot),
    );
  }

  List<Map<String, dynamic>> _grantRows(Object? data, String context) {
    if (data is! List) {
      throw FormatException('$context: expected a list of grants');
    }
    return [
      for (final row in data)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }
}
