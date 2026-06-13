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
  });

  /// POST `/api/v1/folders/{id}/update`.
  Future<void> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  });

  /// POST `/api/v1/folders/{id}/update/parent`.
  Future<void> updateFolderParent(String id, String? parentId);

  /// DELETE `/api/v1/folders/{id}?delete_contents=false`.
  ///
  /// BINDING: sync-driven deletes pass `delete_contents=false` — the server
  /// default is `true`, which ALSO deletes every contained chat (verified
  /// `routers/folders.py:delete_folder_by_id`).
  Future<void> deleteFolder(String id, {bool deleteContents = false});
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
      if (status == 404 || status == 401) {
        return false;
      }
      rethrow;
    }
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
    return api.createChatRaw(chatBlob, folderId: folderId);
  }

  @override
  Future<Map<String, dynamic>?> updateChat(
    String id,
    Map<String, dynamic> fullBlob,
  ) {
    return api.updateChatRaw(id, fullBlob);
  }

  @override
  Future<bool> deleteChat(String id) {
    return api.deleteChatRaw(id);
  }

  @override
  Future<bool> getChatPinned(String id) {
    return api.getChatPinnedRaw(id);
  }

  @override
  Future<Map<String, dynamic>?> togglePin(String id) {
    return api.togglePinRaw(id);
  }

  @override
  Future<Map<String, dynamic>?> toggleArchive(String id) {
    return api.toggleArchiveRaw(id);
  }

  @override
  Future<Map<String, dynamic>?> moveChatToFolder(String id, String? folderId) {
    return api.moveChatToFolderRaw(id, folderId);
  }

  @override
  Future<Map<String, dynamic>> createFolder({
    required String name,
    String? parentId,
  }) {
    return api.createFolder(name: name, parentId: parentId);
  }

  @override
  Future<void> updateFolder(
    String id, {
    String? name,
    Map<String, dynamic>? data,
    Map<String, dynamic>? meta,
  }) {
    return api.updateFolder(id, name: name, data: data, meta: meta);
  }

  @override
  Future<void> updateFolderParent(String id, String? parentId) {
    return api.updateFolderParent(id, parentId);
  }

  @override
  Future<void> deleteFolder(String id, {bool deleteContents = false}) {
    return api.deleteFolderRaw(id, deleteContents: deleteContents);
  }
}

/// Overridable seam for engine tests; null when no [ApiService] is available
/// (no active server / reviewer mode).
@Riverpod(keepAlive: true)
SyncApiClient? syncApiClient(Ref ref) {
  final api = ref.watch(apiServiceProvider);
  return api == null ? null : ApiSyncApiClient(api);
}
