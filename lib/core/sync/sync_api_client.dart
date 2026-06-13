import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import '../services/api_service.dart';

part 'sync_api_client.g.dart';

/// Thin client seam so `PullSync` is unit-testable against
/// `FakeOpenWebUiServer` (CDT-RFC-001 Phase 1).
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

  /// GET `/api/v1/folders/` — (raw folder maps, featureEnabled=false on 403).
  Future<(List<Map<String, dynamic>>, bool)> getFoldersRaw();
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
  Future<(List<Map<String, dynamic>>, bool)> getFoldersRaw() {
    return api.getFolders();
  }
}

/// Overridable seam for engine tests; null when no [ApiService] is available
/// (no active server / reviewer mode).
@Riverpod(keepAlive: true)
SyncApiClient? syncApiClient(Ref ref) {
  final api = ref.watch(apiServiceProvider);
  return api == null ? null : ApiSyncApiClient(api);
}
