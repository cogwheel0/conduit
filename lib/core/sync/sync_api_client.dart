import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import '../services/api_service.dart';

part 'sync_api_client.g.dart';

/// Non-retryable server error (CDT-RFC-001 §7.2 / B5).
///
/// Thrown by [SyncApiClient] write methods for HTTP 401/403 (not owner / no
/// permission). The drainer's `isTerminalServerError` checks
/// `e is SyncTerminalException` and parks the op rather than backing off.
/// 404 is NOT modeled as terminal here: for delete it means already-gone
/// (success), for update it is handled inline (Phase 2: log + done).
class SyncTerminalException implements Exception {
  const SyncTerminalException({this.statusCode, required this.message});

  final int? statusCode;
  final String message;

  @override
  String toString() => 'SyncTerminalException($statusCode): $message';
}

/// Thin client seam so `PullSync`/`PushSync` are unit-testable against
/// `FakeOpenWebUiServer` (CDT-RFC-001 Phase 1 + Phase 2).
abstract interface class SyncApiClient {
  /// GET `/api/v1/chats/?page=N&include_pinned=true&include_folders=true`
  ///
  /// Raw `ChatTitleIdResponse` maps:
  /// `{id, title, updated_at, created_at, last_read_at}`.
  Future<List<Map<String, dynamic>>> getChatListPage(int page);

  /// GET `/api/v1/chats/archived?page=N&order_by=updated_at&direction=desc` —
  /// raw maps.
  ///
  /// (4th call beyond the planned three: required by Q-03 default "archived
  /// metadata only"; the main list ALWAYS excludes archived server-side.)
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page);

  /// GET `/api/v1/chats/{id}` — raw `ChatResponse` map; null on 404.
  Future<Map<String, dynamic>?> getChatRaw(String id);

  /// Reconcile-only existence probe (CDT-RFC-001 §7.5). Returns:
  ///   * `true`  — the chat still exists (it was merely absent from a
  ///     pagination page; do NOT purge).
  ///   * `false` — confirmed gone (HTTP 404 OR the vendored normal-user
  ///     not-ours 401 `ERROR_MESSAGES.NOT_FOUND`, `routers/chats.py`).
  ///   * throws — any OTHER error (network/5xx); the caller skips this
  ///     candidate this run (best-effort, re-runs).
  ///
  /// BINDING: the 401-means-gone interpretation lives ONLY here, never in the
  /// shared pull path (`getChatRaw` keeps 401 as an error so an expired token
  /// never reads as a mass delete on the pull side).
  Future<bool> probeChatExists(String id);

  /// GET `/api/v1/folders/` — (raw folder maps, featureEnabled=false on 403).
  Future<(List<Map<String, dynamic>>, bool)> getFoldersRaw();

  // ---- Phase 2 write extensions (CDT-RFC-001 §7.2/§7.4, B1) ----

  /// POST `/api/v1/chats/new` body `{chat: chatBlob, folder_id: folderId}`.
  ///
  /// [chatBlob] MUST be the COMPLETE `rowsToBlob` blob with `id` set to `''`
  /// (the server mints the row id and ignores any blob `id` —
  /// `routers/chats.py:create_new_chat`). Returns the full `ChatResponse`
  /// map (`id`, `created_at`, `updated_at`).
  Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> chatBlob, {
    String? folderId,
  });

  /// POST `/api/v1/chats/{id}` body `{chat: fullBlob}`.
  ///
  /// [fullBlob] is the COMPLETE `rowsToBlob` blob (§3.iii — NEVER partial: the
  /// route does a shallow top-level merge, so an omitted top-level key
  /// silently keeps the stale server value). Returns the `ChatResponse` map;
  /// null on 404 (chat gone). 401/403 (not owner) throws
  /// [SyncTerminalException].
  Future<Map<String, dynamic>?> updateChat(
    String id,
    Map<String, dynamic> fullBlob,
  );

  /// DELETE `/api/v1/chats/{id}`. `true` on success; 404 (already-gone) ->
  /// `false` WITHOUT throwing. 401/403 (no delete perm) throws
  /// [SyncTerminalException].
  Future<bool> deleteChat(String id);

  /// GET `/api/v1/chats/{id}/pinned` -> bool. (Toggle-delta source for
  /// pin/archive; see [togglePin].)
  Future<bool> getChatPinned(String id);

  /// POST `/api/v1/chats/{id}/pin` — a stateless TOGGLE that IGNORES the
  /// request body (verified `routers/chats.py:pin_chat_by_id`). Returns the
  /// `ChatResponse` after the flip; null on 404.
  Future<Map<String, dynamic>?> togglePin(String id);

  /// POST `/api/v1/chats/{id}/archive` — a stateless TOGGLE that IGNORES the
  /// request body (verified `routers/chats.py:archive_chat_by_id`). Returns
  /// the `ChatResponse` after the flip; null on 404.
  Future<Map<String, dynamic>?> toggleArchive(String id);

  /// POST `/api/v1/chats/{id}/folder` body `{folder_id: folderId}`. The
  /// `update_chat` route IGNORES `folder_id`, so folder moves MUST go through
  /// this dedicated endpoint. Returns the `ChatResponse`; null on 404.
  Future<Map<String, dynamic>?> moveChatToFolder(String id, String? folderId);

  // ---- folder writes ----

  /// POST `/api/v1/folders/` — server mints the id; returns the folder map.
  Future<Map<String, dynamic>> createFolder({
    required String name,
    String? parentId,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  });

  /// POST `/api/v1/folders/{id}/update`; null on 404.
  Future<Map<String, dynamic>?> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  });

  /// POST `/api/v1/folders/{id}/update/parent`; false on 404.
  Future<bool> updateFolderParent(String id, String? parentId);

  /// DELETE `/api/v1/folders/{id}?delete_contents=false`. `true` on success;
  /// 404 (already-gone) -> `false` WITHOUT throwing. 401/403 throws
  /// [SyncTerminalException].
  ///
  /// BINDING: sync-driven deletes pass `delete_contents=false` — the server
  /// default is `true`, which ALSO deletes every contained chat (verified
  /// `routers/folders.py:delete_folder_by_id`).
  Future<bool> deleteFolder(String id, {bool deleteContents = false});

  // ---- Phase 5 NOTES (CDT-RFC-001 D-11) ----
  //
  // All note timestamps in these payloads are server NANOSECONDS (R-09); this
  // seam copies them verbatim and never converts units.

  /// GET `/api/v1/notes/` — the note list ordered `updated_at` DESC (vendored
  /// `routers/notes.py:get_notes`). Raw `NoteUserResponse` maps
  /// `{id, title, data, is_pinned, updated_at, created_at, user}`.
  ///
  /// WARNING: the list endpoint TRUNCATES `data['content']['md']` to 1000 chars
  /// (`_truncate_note_data`), so list `data` is NOT authoritative — the pull
  /// uses the list only for `{id, updated_at}` and full-fetches each changed
  /// note via [getNoteRaw]. The bool is featureEnabled (false on 401/403, the
  /// vendored "notes feature disabled / no permission" response).
  Future<(List<Map<String, dynamic>>, bool)> getNoteListRaw({int? page});

  /// GET `/api/v1/notes/{id}` — the FULL (untruncated) `NoteResponse` map;
  /// null on 404. 401/403 (not owner / no read) throws
  /// [SyncTerminalException], so callers do not collapse auth/permission
  /// failures into permanent absence.
  Future<Map<String, dynamic>?> getNoteRaw(String id);

  /// POST `/api/v1/notes/create` body `{title, data, meta?}`. The server mints
  /// the id + the ns timestamps. Returns the full `NoteModel` map. Own-notes
  /// sync NEVER sends `access_grants`/`access_control` (D-11). 401/403 throws
  /// [SyncTerminalException].
  Future<Map<String, dynamic>> createNote({
    required String title,
    required Map<String, dynamic> data,
    Map<String, dynamic>? meta,
  });

  /// POST `/api/v1/notes/{id}/update` body = the patch map ([patch] ALWAYS
  /// carries `title`; `data` only when the data axis changed — WARNING B).
  /// Returns the updated `NoteModel` map; null on 404 (gone). 401/403 throws
  /// [SyncTerminalException].
  Future<Map<String, dynamic>?> updateNote(
    String id,
    Map<String, dynamic> patch,
  );

  /// DELETE `/api/v1/notes/{id}/delete` -> bool. `true` on success; 404
  /// (already-gone) -> `false` WITHOUT throwing. 401/403 throws
  /// [SyncTerminalException].
  Future<bool> deleteNote(String id);

  /// POST `/api/v1/notes/{id}/pin` — a stateless TOGGLE (vendored
  /// `pin_note_by_id` flips the per-user pinned state, IGNORING the body).
  /// Returns the `NoteModel` after the flip (`is_pinned` reflects the new
  /// state); null on 404. 401/403 throws [SyncTerminalException].
  Future<Map<String, dynamic>?> togglePinNote(String id);
}

/// Production implementation over [ApiService].
class ApiSyncApiClient implements SyncApiClient {
  ApiSyncApiClient(this.api);

  final ApiService api;

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) {
    return api.getChatListPageRaw(
      page: page,
      includePinned: true,
      includeFolders: true,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page) {
    return api.getArchivedChatListPageRaw(page: page);
  }

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) {
    return api.getChatRaw(id);
  }

  @override
  Future<bool> probeChatExists(String id) async {
    // §7.5 reconcile-only: 404 (getChatRaw -> null) AND the vendored
    // normal-user 401 NOT_FOUND both mean "gone". Any other failure rethrows
    // so the reconcile loop skips (does NOT purge) this candidate this run.
    try {
      final resp = await api.getChatRaw(id);
      return resp != null;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404) {
        return false;
      }
      if (status == 401 && _isVendoredNotFound401(e.response?.data)) {
        return false;
      }
      rethrow;
    }
  }

  bool _isVendoredNotFound401(Object? data) {
    return _responseErrorStrings(data).any(_looksLikeNotFound);
  }

  Iterable<String> _responseErrorStrings(Object? data) sync* {
    if (data is Map) {
      for (final key in const ['detail', 'error', 'message']) {
        final value = data[key];
        if (value != null) yield value.toString();
      }
      return;
    }
    if (data is List<int>) {
      yield* _responseErrorStrings(utf8.decode(data, allowMalformed: true));
      return;
    }
    if (data is String) {
      try {
        yield* _responseErrorStrings(jsonDecode(data));
      } on FormatException {
        // Fall through and inspect the raw text below.
      }
      yield data;
    }
  }

  bool _looksLikeNotFound(String value) {
    final lower = value.toLowerCase();
    return lower.contains('not found') ||
        lower.contains("could not find what you're looking for");
  }

  @override
  Future<(List<Map<String, dynamic>>, bool)> getFoldersRaw() {
    return api.getFolders();
  }

  @override
  Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> chatBlob, {
    String? folderId,
  }) {
    return _withTerminalAuth(
      () => api.createChatRaw(chatBlob, folderId: folderId),
      'createChat',
    );
  }

  @override
  Future<Map<String, dynamic>?> updateChat(
    String id,
    Map<String, dynamic> fullBlob,
  ) {
    return _withTerminalAuth(
      () => api.updateChatRaw(id, fullBlob),
      'updateChat $id',
    );
  }

  @override
  Future<bool> deleteChat(String id) {
    return _withTerminalAuth(() => api.deleteChatRaw(id), 'deleteChat $id');
  }

  @override
  Future<bool> getChatPinned(String id) {
    return _withTerminalAuth(
      () => api.getChatPinnedRaw(id),
      'getChatPinned $id',
    );
  }

  @override
  Future<Map<String, dynamic>?> togglePin(String id) {
    return _withTerminalAuth(() => api.togglePinRaw(id), 'togglePin $id');
  }

  @override
  Future<Map<String, dynamic>?> toggleArchive(String id) {
    return _withTerminalAuth(
      () => api.toggleArchiveRaw(id),
      'toggleArchive $id',
    );
  }

  @override
  Future<Map<String, dynamic>?> moveChatToFolder(String id, String? folderId) {
    return _withTerminalAuth(
      () => api.moveChatToFolderRaw(id, folderId),
      'moveChatToFolder $id',
    );
  }

  Future<T> _withTerminalAuth<T>(
    Future<T> Function() action,
    String operation,
  ) async {
    try {
      return await action();
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: '$operation forbidden',
        );
      }
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> createFolder({
    required String name,
    String? parentId,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) {
    return api.createFolder(
      name: name,
      parentId: parentId,
      data: data,
      meta: meta,
    );
  }

  @override
  Future<Map<String, dynamic>?> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) async {
    try {
      return await api.updateFolder(id, name: name, data: data, meta: meta);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return null;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'updateFolder $id forbidden',
        );
      }
      rethrow;
    }
  }

  @override
  Future<bool> updateFolderParent(String id, String? parentId) async {
    try {
      await api.updateFolderParent(id, parentId);
      return true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404) return false;
      if (code == 401 || code == 403) {
        throw SyncTerminalException(
          statusCode: code,
          message: 'updateFolderParent $id forbidden',
        );
      }
      rethrow;
    }
  }

  @override
  Future<bool> deleteFolder(String id, {bool deleteContents = false}) {
    return api.deleteFolderRaw(id, deleteContents: deleteContents);
  }

  // ---- Phase 5 NOTES ----

  @override
  Future<(List<Map<String, dynamic>>, bool)> getNoteListRaw({int? page}) {
    return api.getNotes(page: page);
  }

  @override
  Future<Map<String, dynamic>?> getNoteRaw(String id) {
    return api.getNoteRaw(id);
  }

  @override
  Future<Map<String, dynamic>> createNote({
    required String title,
    required Map<String, dynamic> data,
    Map<String, dynamic>? meta,
  }) {
    return api.createNoteRaw(title: title, data: data, meta: meta);
  }

  @override
  Future<Map<String, dynamic>?> updateNote(
    String id,
    Map<String, dynamic> patch,
  ) {
    return api.updateNoteRaw(id, patch);
  }

  @override
  Future<bool> deleteNote(String id) {
    return api.deleteNoteRaw(id);
  }

  @override
  Future<Map<String, dynamic>?> togglePinNote(String id) {
    return api.togglePinNoteRaw(id);
  }
}

/// Overridable seam for engine tests; null when no [ApiService] is available
/// (no active server / reviewer mode).
@Riverpod(keepAlive: true)
SyncApiClient? syncApiClient(Ref ref) {
  final api = ref.watch(apiServiceProvider);
  return api == null ? null : ApiSyncApiClient(api);
}
