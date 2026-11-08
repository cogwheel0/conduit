import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:conduit_core/features/librechat/models/librechat_message.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';

/// A conversation's share link: its share id, and whether it shares the
/// chat's files (null when the server does not say, which LibreChat reads
/// as sharing them).
typedef LibreChatSharedLink = ({String shareId, bool? snapshotFiles});

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

  // ---- files ----------------------------------------------------------------

  /// Uploads [bytes] as [filename] for a turn on [endpoint]. [fileId] is the
  /// UUID the client mints for it (LibreChat requires one). Images go to
  /// `/api/files/images` with their [imageSize], other files to
  /// `/api/files`.
  ///
  /// Returns LibreChat's file record: `{file_id, filepath, filename, type,
  /// bytes, width, height, ...}`, which the turn sends back in `files`.
  Future<Map<String, dynamic>> uploadFile({
    required Uint8List bytes,
    required String filename,
    required String fileId,
    required String endpoint,
    String? endpointType,
    String? mimeType,
    ({int width, int height})? imageSize,
    String? conversationId,
    String? agentId,
    String? toolResource,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final form = FormData.fromMap({
      'file_id': fileId,
      'endpoint': endpoint,
      'endpointType': ?endpointType,
      'conversationId': ?conversationId,
      'agent_id': ?agentId,
      'tool_resource': ?toolResource,
      'message_file': 'true',
      if (imageSize != null) 'width': imageSize.width,
      if (imageSize != null) 'height': imageSize.height,
      'file': MultipartFile.fromBytes(
        bytes,
        // LibreChat decodes the name as a URI component, and refuses one
        // that does not decode (`50%.pdf`), so it is sent encoded, as its
        // own client sends it.
        filename: Uri.encodeComponent(filename),
        contentType: mimeType == null ? null : DioMediaType.parse(mimeType),
      ),
    });
    try {
      final response = await _dio.post<dynamic>(
        imageSize != null ? '/api/files/images' : '/api/files',
        data: form,
        onSendProgress: onProgress,
        cancelToken: cancelToken,
        options: Options(receiveTimeout: const Duration(minutes: 5)),
      );
      return _map(response.data);
    } on DioException catch (error) {
      throw libreChatErrorOf(error, fallback: 'The upload failed.');
    }
  }

  /// The server's upload limits: `{endpoint: {fileLimit, fileSizeLimit,
  /// supportedMimeTypes}, serverFileSizeLimit, avatarSizeLimit}`.
  Future<Map<String, dynamic>> fileConfig() async =>
      _map(await _get('/api/files/config'));

  // ---- MCP --------------------------------------------------------------------

  /// The user's MCP servers and their tools: `{serverName: {name, icon,
  /// authenticated, authConfig, tools: [{name, pluginKey, description}]}}`.
  Future<Map<String, dynamic>> mcpServers() async {
    final data = _map(await _get('/api/mcp/tools'));
    final servers = data['servers'];
    return servers is Map ? Map<String, dynamic>.from(servers) : {};
  }

  /// The MCP servers the user can reach, by name, with their settings,
  /// including whether chat may pick them (`chatMenu`, `consumeOnly`).
  Future<Map<String, dynamic>> mcpServerSettings() async =>
      _map(await _get('/api/mcp/servers'));

  /// Each MCP server's connection: `{serverName: {connectionState,
  /// requiresOAuth}}`.
  Future<Map<String, dynamic>> mcpConnectionStatus() async {
    final data = _map(await _get('/api/mcp/connection/status'));
    final status = data['connectionStatus'];
    return status is Map ? Map<String, dynamic>.from(status) : {};
  }

  // ---- prompts --------------------------------------------------------------

  /// Every prompt group the user may use, with its production prompt.
  Future<List<Map<String, dynamic>>> promptGroups() async {
    final data = await _get('/api/prompts/all');
    return [
      if (data is List)
        for (final group in data)
          if (group is Map) Map<String, dynamic>.from(group),
    ];
  }

  // ---- memories -------------------------------------------------------------

  /// `{memories: [{key, value, tokenCount, updated_at}], totalTokens,
  /// tokenLimit, usagePercentage}`.
  Future<Map<String, dynamic>> memories() async =>
      _map(await _get('/api/memories'));

  Future<void> createMemory(String key, String value) =>
      _post('/api/memories', {'key': key, 'value': value});

  /// Changes memory [key]'s value, and its key to [newKey] when given.
  Future<void> updateMemory(String key, String value, {String? newKey}) async {
    final path = await _memoryUpdatePath(key);
    try {
      await _dio.patch<dynamic>(path, data: {'value': value, 'key': ?newKey});
    } on DioException catch (error) {
      throw libreChatErrorOf(error);
    }
  }

  /// Where memory [key] is changed. LibreChat answers a PATCH of
  /// `/api/memories/preferences` with the memory preferences, not the
  /// memory of that name, so that one is changed by its id.
  Future<String> _memoryUpdatePath(String key) async {
    if (key == 'preferences') {
      final list = (await memories())['memories'];
      for (final memory in list is List ? list : const <Object?>[]) {
        // An agent's memory of that name is not the user's own, which is the
        // one the id route changes when no agent is named.
        if (memory is! Map ||
            memory['key'] != key ||
            memory['agentId'] != null) {
          continue;
        }
        final id = memory['_id'];
        if (id is String && id.isNotEmpty) {
          return '/api/memories/id/${Uri.encodeComponent(id)}';
        }
      }
    }
    return '/api/memories/${Uri.encodeComponent(key)}';
  }

  Future<void> deleteMemory(String key) async {
    try {
      await _dio.delete<dynamic>('/api/memories/${Uri.encodeComponent(key)}');
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return;
      throw libreChatErrorOf(error);
    }
  }

  /// Whether the assistant may use and update memories for this user.
  Future<void> setMemoriesEnabled(bool enabled) async {
    try {
      await _dio.patch<dynamic>(
        '/api/memories/preferences',
        data: {'memories': enabled},
      );
    } on DioException catch (error) {
      throw libreChatErrorOf(error);
    }
  }

  // ---- sharing, forking -----------------------------------------------------

  /// Conversation [id]'s share link, or null when it has none.
  Future<LibreChatSharedLink?> sharedLink(String id) async {
    final data = _map(
      await _get('/api/share/link/${Uri.encodeComponent(id)}'),
    );
    final shareId = data['shareId'];
    if (shareId is! String || shareId.isEmpty) return null;
    final snapshotFiles = data['snapshotFiles'];
    return (
      shareId: shareId,
      snapshotFiles: snapshotFiles is bool ? snapshotFiles : null,
    );
  }

  /// The share id of conversation [id]'s link, or null when it has none.
  Future<String?> sharedLinkId(String id) async =>
      (await sharedLink(id))?.shareId;

  /// Shares conversation [id] up to [targetMessageId] (its latest message by
  /// default) and returns the share id.
  Future<String> createSharedLink(String id, {String? targetMessageId}) async {
    try {
      final response = await _dio.post<dynamic>(
        '/api/share/${Uri.encodeComponent(id)}',
        data: {'targetMessageId': ?targetMessageId},
      );
      final shareId = _map(response.data)['shareId'];
      if (shareId is String && shareId.isNotEmpty) return shareId;
      throw const LibreChatApiException(
        message: 'The LibreChat server did not create the link.',
      );
    } on DioException catch (error) {
      throw libreChatErrorOf(error, fallback: 'Could not share the chat.');
    }
  }

  /// Snapshots shared link [shareId]'s conversation as it is now, under the
  /// same link, and returns the share id the server reports for it.
  ///
  /// [snapshotFiles] is the link's own choice about the chat's files, as
  /// [sharedLink] read it. LibreChat takes an update that leaves it out as
  /// sharing them, which would hand the files to a link made without them.
  Future<String> refreshSharedLink(
    String shareId, {
    required bool? snapshotFiles,
  }) async {
    try {
      final response = await _dio.patch<dynamic>(
        '/api/share/${Uri.encodeComponent(shareId)}',
        data: <String, dynamic>{'snapshotFiles': ?snapshotFiles},
      );
      final next = _map(response.data)['shareId'];
      return next is String && next.isNotEmpty ? next : shareId;
    } on DioException catch (error) {
      throw libreChatErrorOf(error, fallback: 'Could not update the link.');
    }
  }

  Future<void> deleteSharedLink(String shareId) async {
    try {
      await _dio.delete<dynamic>('/api/share/${Uri.encodeComponent(shareId)}');
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return;
      throw libreChatErrorOf(error);
    }
  }

  /// Copies conversation [id] up to [messageId] into a new conversation.
  /// [option] is LibreChat's `directPath`, `includeBranches` or
  /// `targetLevel`. Returns the new conversation and its messages.
  Future<({LibreChatConversation conversation, List<LibreChatMessage> messages})>
  fork(
    String id, {
    required String messageId,
    String option = 'directPath',
  }) => _copy('/api/convos/fork', {
    'conversationId': id,
    'messageId': messageId,
    'option': option,
    'splitAtTarget': false,
    'latestMessageId': messageId,
  });

  /// Copies conversation [id] whole into a new one.
  Future<({LibreChatConversation conversation, List<LibreChatMessage> messages})>
  duplicate(String id, {String? title}) => _copy('/api/convos/duplicate', {
    'conversationId': id,
    'title': ?title,
  });

  Future<({LibreChatConversation conversation, List<LibreChatMessage> messages})>
  _copy(String path, Map<String, dynamic> body) async {
    try {
      final data = _map((await _dio.post<dynamic>(path, data: body)).data);
      final conversation = LibreChatConversation.fromJson(
        data['conversation'],
      );
      if (conversation == null) {
        throw const LibreChatApiException(
          message: 'The LibreChat server did not return the new chat.',
        );
      }
      final list = data['messages'];
      return (
        conversation: conversation,
        messages: [
          if (list is List)
            for (final item in list) ?LibreChatMessage.fromJson(item),
        ],
      );
    } on DioException catch (error) {
      throw libreChatErrorOf(error);
    }
  }

  // ---- speech ---------------------------------------------------------------

  /// The admin's speech settings for clients (`/api/files/speech/config/get`).
  Future<Map<String, dynamic>> speechConfig() async =>
      _map(await _get('/api/files/speech/config/get'));

  /// The voices the server's text-to-speech offers.
  Future<List<String>> voices() async {
    final data = await _get('/api/files/speech/tts/voices');
    return [
      if (data is List)
        for (final voice in data)
          if (voice is String && voice.isNotEmpty) voice,
    ];
  }

  /// Transcribes [audio] with the server's speech-to-text.
  Future<String> transcribe(
    Uint8List audio, {
    required String filename,
    String? mimeType,
    String? language,
    CancelToken? cancelToken,
  }) async {
    final form = FormData.fromMap({
      'language': ?language,
      'audio': MultipartFile.fromBytes(
        audio,
        // Decoded on arrival, as an upload's is: see [uploadFile].
        filename: Uri.encodeComponent(filename),
        contentType: mimeType == null ? null : DioMediaType.parse(mimeType),
      ),
    });
    try {
      final response = await _dio.post<dynamic>(
        '/api/files/speech/stt',
        data: form,
        cancelToken: cancelToken,
      );
      final text = _map(response.data)['text'];
      return text is String ? text : '';
    } on DioException catch (error) {
      throw libreChatErrorOf(error, fallback: 'Transcription failed.');
    }
  }

  /// [text] spoken by the server's text-to-speech in [voice]: the audio,
  /// and its media type when the server named an audio one.
  Future<({Uint8List bytes, String? mimeType})> synthesize(
    String text, {
    String? voice,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post<List<int>>(
        '/api/files/speech/tts/manual',
        data: FormData.fromMap({'input': text, 'voice': ?voice}),
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.bytes),
      );
      final type = response.headers
          .value(Headers.contentTypeHeader)
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      return (
        bytes: Uint8List.fromList(response.data ?? const <int>[]),
        mimeType: type != null && type.startsWith('audio/') ? type : null,
      );
    } on DioException catch (error) {
      throw libreChatErrorOf(error, fallback: 'Speech failed.');
    }
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

  /// [data] as a JSON object, or an empty one. LibreChat sends some as text
  /// (its endpoints config is `res.send(JSON.stringify(...))`, so
  /// `text/html`), which Dio leaves a string.
  static Map<String, dynamic> _map(Object? data) {
    var value = data;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        return <String, dynamic>{};
      }
    }
    return value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{};
  }
}
