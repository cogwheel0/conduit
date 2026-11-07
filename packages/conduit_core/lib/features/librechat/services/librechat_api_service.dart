import 'package:dio/dio.dart';

import 'package:conduit_core/features/librechat/models/librechat_message.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';

/// The REST routes of one signed-in LibreChat server (v0.8.8), other than
/// generation, which [LibreChatStreamClient] owns.
///
/// Answers come back as LibreChat sends them: typed where Conduit reads them
/// field by field, raw maps where a later step interprets them.
final class LibreChatApiService {
  LibreChatApiService(this._client);

  final LibreChatHttpClient _client;

  Dio get _dio => _client.dio;

  // ---- account --------------------------------------------------------------

  Future<LibreChatUser> currentUser() async {
    final data = await _get('/api/user');
    return LibreChatUser.fromJson(data) ??
        (throw const LibreChatApiException(
          message: 'The LibreChat server did not say who is signed in.',
        ));
  }

  /// The startup config with the signed-in parts: `interface` flags,
  /// `modelSpecs`, `balance`, `sharedLinksEnabled`, ...
  Future<Map<String, dynamic>> startupConfig() async =>
      _map(await _get('/api/config'));

  /// The permissions of [role] (`/api/roles/:role`), by feature:
  /// `{PROMPTS: {USE: true, CREATE: true}, MEMORIES: {...}, ...}`.
  Future<Map<String, dynamic>> rolePermissions(String role) async {
    final data = _map(await _get('/api/roles/${Uri.encodeComponent(role)}'));
    final permissions = data['permissions'];
    return permissions is Map ? Map<String, dynamic>.from(permissions) : data;
  }

  /// Whether the server can search conversations (Meilisearch is set up).
  Future<bool> searchEnabled() async =>
      await _get('/api/search/enable') == true;

  // ---- conversations --------------------------------------------------------

  /// One page of conversations, newest first. [archived] lists the archive
  /// instead; [pinnedOnly] lists only pinned ones.
  Future<LibreChatConversationPage> conversations({
    String? cursor,
    int limit = 100,
    bool archived = false,
    bool pinnedOnly = false,
    String? search,
    CancelToken? cancelToken,
  }) async {
    final data = _map(
      await _get(
        '/api/convos',
        query: {
          'limit': limit,
          'cursor': ?cursor,
          if (archived) 'isArchived': true,
          if (pinnedOnly) 'pinned': true,
          if (search != null && search.trim().isNotEmpty)
            'search': search.trim(),
        },
        cancelToken: cancelToken,
      ),
    );
    final list = data['conversations'];
    final next = data['nextCursor'];
    return LibreChatConversationPage([
      if (list is List)
        for (final item in list) ?LibreChatConversation.fromJson(item),
    ], next is String && next.isNotEmpty ? next : null);
  }

  /// One conversation, or null when the server has none by [id].
  Future<LibreChatConversation?> conversation(
    String id, {
    CancelToken? cancelToken,
  }) async {
    try {
      return LibreChatConversation.fromJson(
        await _get(
          '/api/convos/${Uri.encodeComponent(id)}',
          cancelToken: cancelToken,
        ),
      );
    } on LibreChatApiException catch (error) {
      if (error.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Every message of conversation [id], every branch, in no set order.
  Future<List<LibreChatMessage>> messages(
    String id, {
    CancelToken? cancelToken,
  }) async {
    final data = await _get(
      '/api/messages/${Uri.encodeComponent(id)}',
      cancelToken: cancelToken,
    );
    return [
      if (data is List)
        for (final item in data) ?LibreChatMessage.fromJson(item),
    ];
  }

  Future<void> renameConversation(String id, String title) =>
      _post('/api/convos/update', {
        'arg': {'conversationId': id, 'title': title},
      });

  Future<void> setArchived(String id, bool archived) =>
      _post('/api/convos/archive', {
        'arg': {'conversationId': id, 'isArchived': archived},
      });

  Future<void> setPinned(String id, bool pinned) => _post('/api/convos/pin', {
    'arg': {'conversationId': id, 'pinned': pinned},
  });

  /// Deletes conversation [id]. One already gone counts as deleted.
  Future<void> deleteConversation(String id) async {
    try {
      await _dio.delete<dynamic>(
        '/api/convos',
        data: {
          'arg': {'conversationId': id, 'source': 'button'},
        },
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return;
      throw libreChatErrorOf(error);
    }
  }

  // ---- what to chat with ----------------------------------------------------

  /// `{endpointName: {type, userProvide, order, capabilities, ...}}`. A
  /// disabled endpoint is missing or null.
  Future<Map<String, dynamic>> endpoints() async =>
      _map(await _get('/api/endpoints'));

  /// `{endpointName: [model, ...]}`.
  Future<Map<String, List<String>>> models() async {
    final data = _map(await _get('/api/models'));
    return {
      for (final entry in data.entries)
        if (entry.value is List)
          entry.key: [
            for (final model in entry.value as List)
              if (model is String && model.isNotEmpty) model,
          ],
    };
  }

  /// The agents the user may chat with, every page.
  Future<List<Map<String, dynamic>>> agents() async {
    final agents = <Map<String, dynamic>>[];
    String? after;
    for (var page = 0; page < 20; page++) {
      final data = _map(
        await _get(
          '/api/agents',
          query: {'requiredPermission': 1, 'limit': 100, 'cursor': ?after},
        ),
      );
      final list = data['data'];
      if (list is List) {
        for (final agent in list) {
          if (agent is Map) agents.add(Map<String, dynamic>.from(agent));
        }
      }
      final next = data['after'] ?? data['last_id'];
      if (data['has_more'] != true || next is! String || next == after) break;
      after = next;
    }
    return agents;
  }

  // ---- plumbing -------------------------------------------------------------

  Future<Object?> _get(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get<dynamic>(
        path,
        queryParameters: query,
        cancelToken: cancelToken,
      );
      return response.data;
    } on DioException catch (error) {
      throw libreChatErrorOf(error);
    }
  }

  Future<void> _post(String path, Object data) async {
    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(path, data: data);
    } on DioException catch (error) {
      throw libreChatErrorOf(error);
    }
    // LibreChat's saveConvo swallows a failed write and answers it with a
    // success status carrying only this message.
    final body = response.data;
    if (body is Map &&
        body['message'] == _saveFailed &&
        body['conversationId'] == null) {
      throw LibreChatApiException(
        message: _saveFailed,
        statusCode: response.statusCode,
      );
    }
  }

  static const String _saveFailed = 'Error saving conversation';

  static Map<String, dynamic> _map(Object? data) =>
      data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
}
