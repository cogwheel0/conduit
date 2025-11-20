import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:http_parser/http_parser.dart';
// Removed legacy websocket/socket.io imports
import 'package:uuid/uuid.dart';
import '../models/backend_config.dart';
import '../models/server_config.dart';
import '../models/user.dart';
import '../models/model.dart';
import '../models/conversation.dart';
import '../models/chat_message.dart';
import '../models/file_info.dart';
import '../models/knowledge_base.dart';
import '../models/prompt.dart';
import '../auth/api_auth_interceptor.dart';
import '../error/api_error_interceptor.dart';
// Tool-call details are parsed in the UI layer to render collapsible blocks
import 'persistent_streaming_service.dart';
import 'connectivity_service.dart';
import 'sse_stream_parser.dart';
import '../utils/debug_logger.dart';
import 'conversation_parsing.dart';
import 'worker_manager.dart';

const bool _traceApiLogs = false;

void _traceApi(String message) {
  if (!_traceApiLogs) {
    return;
  }
  DebugLogger.log(message, scope: 'api/trace');
}

class ApiService {
  final Dio _dio;
  final ServerConfig serverConfig;
  final WorkerManager _workerManager;
  late final ApiAuthInterceptor _authInterceptor;
  // Removed legacy websocket/socket.io fields

  // Public getter for dio instance
  Dio get dio => _dio;

  // Public getter for base URL
  String get baseUrl => serverConfig.url;

  // Callback to notify when auth token becomes invalid
  void Function()? onAuthTokenInvalid;

  // New callback for the unified auth state manager
  Future<void> Function()? onTokenInvalidated;

  ApiService({
    required this.serverConfig,
    required WorkerManager workerManager,
    String? authToken,
  }) : _dio = Dio(
         BaseOptions(
           baseUrl: serverConfig.url,
           connectTimeout: const Duration(seconds: 30),
           receiveTimeout: const Duration(seconds: 30),
           followRedirects: true,
           maxRedirects: 5,
           validateStatus: (status) => status != null && status < 400,
           // Add custom headers from server config
           headers: serverConfig.customHeaders.isNotEmpty
               ? Map<String, String>.from(serverConfig.customHeaders)
               : null,
         ),
       ),
       _workerManager = workerManager {
    _configureSelfSignedSupport();

    // Use API key from server config if provided and no explicit auth token
    final effectiveAuthToken = authToken ?? serverConfig.apiKey;

    // Initialize the consistent auth interceptor
    _authInterceptor = ApiAuthInterceptor(
      authToken: effectiveAuthToken,
      onAuthTokenInvalid: onAuthTokenInvalid,
      onTokenInvalidated: onTokenInvalidated,
      customHeaders: serverConfig.customHeaders,
    );

    // Add interceptors in order of priority:
    // 1. Auth interceptor (must be first to add auth headers)
    _dio.interceptors.add(_authInterceptor);

    // 2. Validation interceptor removed (no schema loading/logging)

    // 3. Error handling interceptor (transforms errors to standardized format)
    _dio.interceptors.add(
      ApiErrorInterceptor(
        logErrors: kDebugMode,
        throwApiErrors: true, // Transform DioExceptions to include ApiError
      ),
    );

    // 4. Success pings to relax offline detection.
    // Any successful API response indicates recent connectivity; suppress
    // offline transitions briefly to avoid UI flicker.
    _dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (response, handler) {
          try {
            if ((response.statusCode ?? 0) >= 200 &&
                (response.statusCode ?? 0) < 400) {
              ConnectivityService.suppressOfflineGlobally(
                const Duration(seconds: 4),
              );
            }
          } catch (_) {}
          handler.next(response);
        },
      ),
    );

    // 5. Custom debug interceptor to log exactly what we're sending
    if (kDebugMode) {
      _dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.next(options);
          },
        ),
      );

      // LogInterceptor removed - was exposing sensitive data and creating verbose logs
      // We now use custom interceptors with secure logging via DebugLogger
    }

    // Validation interceptor fully removed
  }

  void updateAuthToken(String? token) {
    _authInterceptor.updateAuthToken(token);
  }

  String? get authToken => _authInterceptor.authToken;

  /// Ensure interceptor callbacks stay in sync if they are set after construction
  void setAuthCallbacks({
    void Function()? onAuthTokenInvalid,
    Future<void> Function()? onTokenInvalidated,
  }) {
    if (onAuthTokenInvalid != null) {
      this.onAuthTokenInvalid = onAuthTokenInvalid;
      _authInterceptor.onAuthTokenInvalid = onAuthTokenInvalid;
    }
    if (onTokenInvalidated != null) {
      this.onTokenInvalidated = onTokenInvalidated;
      _authInterceptor.onTokenInvalidated = onTokenInvalidated;
    }
  }

  /// Configures this Dio instance to accept self-signed certificates.
  ///
  /// When [ServerConfig.allowSelfSignedCertificates] is enabled, this method
  /// sets up a [badCertificateCallback] that trusts certificates from the
  /// configured server's host and port.
  ///
  /// Security considerations:
  /// - Only certificates from the exact host/port are trusted
  /// - If no port is specified, all ports on the host are trusted
  /// - Web platforms ignore this (browsers handle TLS validation)
  void _configureSelfSignedSupport() {
    if (kIsWeb || !serverConfig.allowSelfSignedCertificates) {
      return;
    }

    final baseUri = _parseBaseUri(serverConfig.url);
    if (baseUri == null) {
      return;
    }

    final adapter = _dio.httpClientAdapter;
    if (adapter is! IOHttpClientAdapter) {
      return;
    }

    adapter.createHttpClient = () {
      final client = HttpClient();
      final host = baseUri.host.toLowerCase();
      final port = baseUri.hasPort ? baseUri.port : null;
      client.badCertificateCallback =
          (X509Certificate cert, String requestHost, int requestPort) {
            // Only trust certificates from our configured server
            if (requestHost.toLowerCase() != host) {
              return false;
            }
            // If no specific port configured, trust any port on this host
            if (port == null) {
              return true;
            }
            // Otherwise, port must match exactly
            return requestPort == port;
          };
      return client;
    };
  }

  Uri? _parseBaseUri(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    Uri? parsed = Uri.tryParse(trimmed);
    if (parsed == null) {
      return null;
    }
    if (!parsed.hasScheme) {
      parsed =
          Uri.tryParse('https://$trimmed') ?? Uri.tryParse('http://$trimmed');
    }
    return parsed;
  }

  // Health check
  Future<bool> checkHealth() async {
    try {
      final response = await _dio.get('/health');
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // Enhanced health check with model availability
  Future<Map<String, dynamic>> checkServerStatus() async {
    final result = <String, dynamic>{
      'healthy': false,
      'modelsAvailable': false,
      'modelCount': 0,
      'error': null,
    };

    try {
      // Check basic health
      final healthResponse = await _dio.get('/health');
      result['healthy'] = healthResponse.statusCode == 200;

      if (result['healthy']) {
        // Check model availability
        try {
          final modelsResponse = await _dio.get('/api/models');
          final models = modelsResponse.data['data'] as List?;
          result['modelsAvailable'] = models != null && models.isNotEmpty;
          result['modelCount'] = models?.length ?? 0;
        } catch (e) {
          result['modelsAvailable'] = false;
        }
      }
    } catch (e) {
      result['error'] = e.toString();
    }

    return result;
  }

  Future<BackendConfig?> getBackendConfig() async {
    try {
      final response = await _dio.get('/api/config');
      final data = response.data;
      Map<String, dynamic>? jsonMap;
      if (data is Map<String, dynamic>) {
        jsonMap = data;
      } else if (data is String && data.isNotEmpty) {
        final decoded = json.decode(data);
        if (decoded is Map<String, dynamic>) {
          jsonMap = decoded;
        }
      }
      if (jsonMap == null) {
        return null;
      }
      return BackendConfig.fromJson(jsonMap);
    } on DioException catch (e, stackTrace) {
      _traceApi('Backend config request failed: $e');
      DebugLogger.error(
        'backend-config-error',
        scope: 'api/config',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    } catch (e, stackTrace) {
      _traceApi('Backend config decode error: $e');
      DebugLogger.error(
        'backend-config-decode',
        scope: 'api/config',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  // Authentication
  Future<Map<String, dynamic>> login(String username, String password) async {
    try {
      final response = await _dio.post(
        '/api/v1/auths/signin',
        data: {'email': username, 'password': password},
      );

      return response.data;
    } catch (e) {
      if (e is DioException) {
        // Handle specific redirect cases
        if (e.response?.statusCode == 307 || e.response?.statusCode == 308) {
          final location = e.response?.headers.value('location');
          if (location != null) {
            throw Exception(
              'Server redirect detected. Please check your server URL configuration. Redirect to: $location',
            );
          }
        }
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    await _dio.get('/api/v1/auths/signout');
  }

  // User info
  Future<User> getCurrentUser() async {
    final response = await _dio.get('/api/v1/auths/');
    DebugLogger.log('user-info', scope: 'api/user');
    return User.fromJson(response.data);
  }

  // Models
  Future<List<Model>> getModels() async {
    final response = await _dio.get('/api/models');

    // Handle different response formats
    List<dynamic> models;
    if (response.data is Map && response.data['data'] != null) {
      // Response is wrapped in a 'data' field
      models = response.data['data'] as List;
    } else if (response.data is List) {
      // Response is a direct array
      models = response.data as List;
    } else {
      DebugLogger.error('models-format', scope: 'api/models');
      return [];
    }

    DebugLogger.log(
      'models-count',
      scope: 'api/models',
      data: {'count': models.length},
    );
    return models.map((m) => Model.fromJson(m)).toList();
  }

  // Get default model configuration from OpenWebUI user settings
  Future<String?> getDefaultModel() async {
    try {
      final response = await _dio.get('/api/v1/users/user/settings');

      DebugLogger.log('settings-ok', scope: 'api/user-settings');

      final data = response.data;
      if (data is! Map<String, dynamic>) {
        DebugLogger.warning(
          'settings-format',
          scope: 'api/user-settings',
          data: {'type': data.runtimeType},
        );
        return null;
      }

      // Extract default model from ui.models array
      final ui = data['ui'];
      if (ui is Map<String, dynamic>) {
        final models = ui['models'];
        if (models is List && models.isNotEmpty) {
          // Return the first model in the user's preferred models list
          final defaultModel = models.first.toString();
          DebugLogger.log(
            'default-model',
            scope: 'api/user-settings',
            data: {'id': defaultModel},
          );
          return defaultModel;
        }
      }

      DebugLogger.warning('default-model-missing', scope: 'api/user-settings');
      return null;
    } catch (e) {
      DebugLogger.error(
        'default-model-error',
        scope: 'api/user-settings',
        error: e,
      );
      // Do not call admin-only configs endpoint here; let the caller
      // handle fallback (e.g., first available model from /api/models).
      return null;
    }
  }

  // Conversations - Updated to use correct OpenWebUI API
  Future<List<Conversation>> getConversations({int? limit, int? skip}) async {
    List<dynamic> allRegularChats = [];

    if (limit == null) {
      // Fetch all conversations using pagination

      // OpenWebUI expects 1-based pagination for the `page` query param.
      // Using 0 triggers server-side offset calculation like `offset = page*limit - limit`,
      // which becomes negative for page=0 and causes a DB error.
      int currentPage = 1;

      while (true) {
        final response = await _dio.get(
          '/api/v1/chats/',
          queryParameters: {'page': currentPage},
        );

        if (response.data is! List) {
          throw Exception(
            'Expected array of chats, got ${response.data.runtimeType}',
          );
        }

        final pageChats = response.data as List;

        if (pageChats.isEmpty) {
          break;
        }

        allRegularChats.addAll(pageChats);
        currentPage++;

        // Safety break to avoid infinite loops (adjust as needed)
        if (currentPage > 100) {
          _traceApi(
            'WARNING: Reached maximum page limit (100), stopping pagination',
          );
          break;
        }
      }

      _traceApi(
        'Fetched total of ${allRegularChats.length} conversations across $currentPage pages',
      );
    } else {
      // Original single page fetch
      final regularResponse = await _dio.get(
        '/api/v1/chats/',
        // Convert skip/limit to 1-based page index expected by OpenWebUI.
        // Example: skip=0 => page=1, skip=limit => page=2, etc.
        queryParameters: {
          if (limit > 0)
            'page': (((skip ?? 0) / limit).floor() + 1).clamp(1, 1 << 30),
        },
      );

      if (regularResponse.data is! List) {
        throw Exception(
          'Expected array of chats, got ${regularResponse.data.runtimeType}',
        );
      }

      allRegularChats = regularResponse.data as List;
    }

    final pinnedChatList = await _fetchChatCollection(
      '/api/v1/chats/pinned',
      debugLabel: 'pinned chats',
    );
    final archivedChatList = await _fetchChatCollection(
      '/api/v1/chats/all/archived',
      debugLabel: 'archived chats',
    );
    final regularChatList = allRegularChats;

    DebugLogger.log(
      'summary',
      scope: 'api/conversations',
      data: {
        'regular': regularChatList.length,
        'pinned': pinnedChatList.length,
        'archived': archivedChatList.length,
      },
    );

    final parsedJson = await _workerManager
        .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
          parseConversationSummariesWorker,
          {
            'pinned': pinnedChatList,
            'archived': archivedChatList,
            'regular': regularChatList,
          },
          debugLabel: 'parse_conversation_list',
        );

    final conversations = parsedJson
        .map((json) => Conversation.fromJson(json))
        .toList(growable: false);

    DebugLogger.log(
      'parse-complete',
      scope: 'api/conversations',
      data: {
        'total': conversations.length,
        'pinned': conversations.where((c) => c.pinned).length,
        'archived': conversations.where((c) => c.archived).length,
      },
    );
    return conversations;
  }

  Future<List<dynamic>> _fetchChatCollection(
    String path, {
    required String debugLabel,
  }) async {
    final scope = 'api/collection/${debugLabel.replaceAll(' ', '-')}';
    try {
      final response = await _dio.get(path);
      DebugLogger.log(
        'status',
        scope: scope,
        data: {'code': response.statusCode},
      );
      if (response.data is List) {
        return (response.data as List).cast<dynamic>();
      }
      DebugLogger.warning(
        'unexpected-type',
        scope: scope,
        data: {'type': response.data.runtimeType},
      );
    } on DioException catch (e) {
      DebugLogger.warning(
        'network-skip',
        scope: scope,
        data: {'message': e.message},
      );
    } catch (e) {
      DebugLogger.warning('error-skip', scope: scope, data: {'error': e});
    }
    return <dynamic>[];
  }

  // Parse OpenWebUI chat format to our Conversation format
  Future<Conversation> getConversation(String id) async {
    DebugLogger.log('fetch', scope: 'api/chat', data: {'id': id});
    final response = await _dio.get('/api/v1/chats/$id');

    DebugLogger.log('fetch-ok', scope: 'api/chat');

    final json = await _workerManager
        .schedule<Map<String, dynamic>, Map<String, dynamic>>(
          parseFullConversationWorker,
          {'conversation': response.data},
          debugLabel: 'parse_conversation_full',
        );
    return Conversation.fromJson(json);
  }

  // Parse full OpenWebUI chat with messages
  // Parse OpenWebUI message format to our ChatMessage format
  // Build ordered messages list from Open‑WebUI history using parent chain to currentId
  // ===== Helpers to synthesize tool-call details blocks for UI parsing =====
  List<Map<String, dynamic>>? _sanitizeFilesForWebUI(
    List<Map<String, dynamic>>? files,
  ) {
    if (files == null || files.isEmpty) {
      return null;
    }
    final sanitized = <Map<String, dynamic>>[];
    for (final entry in files) {
      final safe = <String, dynamic>{};
      for (final MapEntry(:key, :value) in entry.entries) {
        if (value == null) continue;
        safe[key.toString()] = value;
      }
      if (safe.isNotEmpty) {
        sanitized.add(safe);
      }
    }
    return sanitized.isNotEmpty ? sanitized : null;
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
        if (msg.role == 'user' && model != null) 'models': [model],
        if (msg.attachmentIds != null && msg.attachmentIds!.isNotEmpty)
          'attachment_ids': List<String>.from(msg.attachmentIds!),
        if (_sanitizeFilesForWebUI(msg.files) != null)
          'files': _sanitizeFilesForWebUI(msg.files),
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
        if (msg.role == 'user' && model != null) 'models': [model],
        if (msg.attachmentIds != null && msg.attachmentIds!.isNotEmpty)
          'attachment_ids': List<String>.from(msg.attachmentIds!),
        if (_sanitizeFilesForWebUI(msg.files) != null)
          'files': _sanitizeFilesForWebUI(msg.files),
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
        'history': {
          'messages': messagesMap,
          if (currentId != null) 'currentId': currentId,
        },
        'messages': messagesArray,
        'tags': [],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      },
      'folder_id': folderId,
    };

    _traceApi('Sending chat data with proper parent-child structure');
    _traceApi('Request data: $chatData');

    final response = await _dio.post('/api/v1/chats/new', data: chatData);

    DebugLogger.log(
      'create-status',
      scope: 'api/conversation',
      data: {'code': response.statusCode},
    );
    DebugLogger.log('create-ok', scope: 'api/conversation');

    final responseData = response.data;
    final json = await _workerManager
        .schedule<Map<String, dynamic>, Map<String, dynamic>>(
          parseFullConversationWorker,
          {'conversation': responseData},
          debugLabel: 'parse_conversation_full',
        );
    return Conversation.fromJson(json);
  }

  // Sync conversation messages to ensure WebUI can load conversation history
  Future<void> syncConversationMessages(
    String conversationId,
    List<ChatMessage> messages, {
    String? title,
    String? model,
    String? systemPrompt,
  }) async {
    _traceApi(
      'Syncing conversation $conversationId with ${messages.length} messages',
    );

    // Build messages map and array in OpenWebUI format
    final Map<String, dynamic> messagesMap = {};
    final List<Map<String, dynamic>> messagesArray = [];
    String? currentId;
    String? previousId;
    String? lastUserId;

    for (final msg in messages) {
      final messageId = msg.id;

      // Use the properly formatted files array for WebUI display
      // The msg.files array already contains all attachments in the correct format
      final sanitizedFiles = _sanitizeFilesForWebUI(msg.files);

      // Determine parent id: allow explicit parent override via metadata
      final explicitParent = msg.metadata != null
          ? (msg.metadata!['parentId']?.toString())
          : null;
      // For assistant messages, branch from the last user (OpenWebUI-style)
      final fallbackParent = msg.role == 'assistant'
          ? (lastUserId ?? previousId)
          : previousId;
      final parentId = explicitParent ?? fallbackParent;

      messagesMap[messageId] = {
        'id': messageId,
        'parentId': parentId,
        'childrenIds': <String>[],
        'role': msg.role,
        'content': msg.content,
        'timestamp': msg.timestamp.millisecondsSinceEpoch ~/ 1000,
        if (msg.role == 'assistant' && msg.model != null) 'model': msg.model,
        if (msg.role == 'assistant' && msg.model != null)
          'modelName': msg.model,
        if (msg.role == 'assistant') 'modelIdx': 0,
        if (msg.role == 'assistant') 'done': !msg.isStreaming,
        if (msg.role == 'user' && model != null) 'models': [model],
        if (msg.attachmentIds != null && msg.attachmentIds!.isNotEmpty)
          'attachment_ids': List<String>.from(msg.attachmentIds!),
        if (sanitizedFiles != null) 'files': sanitizedFiles,
      };

      // Update parent's childrenIds
      if (parentId != null && messagesMap.containsKey(parentId)) {
        (messagesMap[parentId]['childrenIds'] as List).add(messageId);
      }

      // Use the same properly formatted files array for messages array
      final sanitizedArrayFiles = _sanitizeFilesForWebUI(msg.files);

      messagesArray.add({
        'id': messageId,
        'parentId': parentId,
        'childrenIds': [],
        'role': msg.role,
        'content': msg.content,
        'timestamp': msg.timestamp.millisecondsSinceEpoch ~/ 1000,
        if (msg.role == 'assistant' && msg.model != null) 'model': msg.model,
        if (msg.role == 'assistant' && msg.model != null)
          'modelName': msg.model,
        if (msg.role == 'assistant') 'modelIdx': 0,
        if (msg.role == 'assistant') 'done': !msg.isStreaming,
        if (msg.role == 'user' && model != null) 'models': [model],
        if (msg.attachmentIds != null && msg.attachmentIds!.isNotEmpty)
          'attachment_ids': List<String>.from(msg.attachmentIds!),
        if (sanitizedArrayFiles != null) 'files': sanitizedArrayFiles,
      });

      previousId = messageId;
      if (msg.role == 'user') {
        lastUserId = messageId;
      }

      // Server-side persistence of assistant versions (OpenWebUI-style)
      if (msg.role == 'assistant' && (msg.versions.isNotEmpty)) {
        final parentForVersions = explicitParent ?? lastUserId ?? previousId;
        for (final ver in msg.versions) {
          final vId = ver.id;
          // Only add if not already present
          if (!messagesMap.containsKey(vId)) {
            messagesMap[vId] = {
              'id': vId,
              'parentId': parentForVersions,
              'childrenIds': <String>[],
              'role': 'assistant',
              'content': ver.content,
              'timestamp': ver.timestamp.millisecondsSinceEpoch ~/ 1000,
              if (ver.model != null) 'model': ver.model,
              if (ver.model != null) 'modelName': ver.model,
              'modelIdx': 0,
              'done': true,
              if (ver.files != null) 'files': _sanitizeFilesForWebUI(ver.files),
            };
            // Link into parent (parentForVersions is always non-null here)
            if (messagesMap.containsKey(parentForVersions)) {
              (messagesMap[parentForVersions]['childrenIds'] as List).add(vId);
            }
          }
        }
      }
      currentId = messageId;
    }

    // Create the chat data structure matching OpenWebUI format exactly
    final chatData = {
      'chat': {
        if (title != null) 'title': title, // Include the title if provided
        'models': model != null ? [model] : [],
        if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
          'system': systemPrompt,
        'messages': messagesArray,
        'history': {
          'messages': messagesMap,
          if (currentId != null) 'currentId': currentId,
        },
        'params': {},
        'files': [],
      },
    };

    _traceApi('Syncing chat with OpenWebUI format data using POST');

    // OpenWebUI uses POST not PUT for updating chats
    await _dio.post('/api/v1/chats/$conversationId', data: chatData);

    DebugLogger.log('sync-ok', scope: 'api/conversation');
  }

  Future<void> updateConversation(
    String id, {
    String? title,
    String? systemPrompt,
  }) async {
    // OpenWebUI expects POST to /api/v1/chats/{id} with ChatForm { chat: {...} }
    final chatPayload = <String, dynamic>{
      if (title != null) 'title': title,
      if (systemPrompt != null) 'system': systemPrompt,
    };
    await _dio.post('/api/v1/chats/$id', data: {'chat': chatPayload});
  }

  Future<void> deleteConversation(String id) async {
    await _dio.delete('/api/v1/chats/$id');
  }

  // Pin/Unpin conversation
  Future<void> pinConversation(String id, bool pinned) async {
    _traceApi('${pinned ? 'Pinning' : 'Unpinning'} conversation: $id');
    await _dio.post('/api/v1/chats/$id/pin', data: {'pinned': pinned});
  }

  // Archive/Unarchive conversation
  Future<void> archiveConversation(String id, bool archived) async {
    _traceApi('${archived ? 'Archiving' : 'Unarchiving'} conversation: $id');
    await _dio.post('/api/v1/chats/$id/archive', data: {'archived': archived});
  }

  // Share conversation
  Future<String?> shareConversation(String id) async {
    _traceApi('Sharing conversation: $id');
    final response = await _dio.post('/api/v1/chats/$id/share');
    final data = response.data as Map<String, dynamic>;
    return data['share_id'] as String?;
  }

  // Clone conversation
  Future<Conversation> cloneConversation(String id) async {
    _traceApi('Cloning conversation: $id');
    final response = await _dio.post('/api/v1/chats/$id/clone');
    final json = await _workerManager
        .schedule<Map<String, dynamic>, Map<String, dynamic>>(
          parseFullConversationWorker,
          {'conversation': response.data},
          debugLabel: 'parse_conversation_full',
        );
    return Conversation.fromJson(json);
  }

  // User Settings
  Future<Map<String, dynamic>> getUserSettings() async {
    _traceApi('Fetching user settings');
    final response = await _dio.get('/api/v1/users/user/settings');
    return response.data as Map<String, dynamic>;
  }

  Future<void> updateUserSettings(Map<String, dynamic> settings) async {
    _traceApi('Updating user settings');
    // Align with web client update route
    await _dio.post('/api/v1/users/user/settings/update', data: settings);
  }

  // Suggestions
  Future<List<String>> getSuggestions() async {
    _traceApi('Fetching conversation suggestions');
    final response = await _dio.get('/api/v1/configs/suggestions');
    final data = response.data;
    if (data is List) {
      return data.cast<String>();
    }
    return [];
  }

  Future<List<Conversation>> _parseConversationSummaryList(
    List<dynamic> regular, {
    required String debugLabel,
  }) async {
    final payload = <String, dynamic>{
      'regular': List<dynamic>.from(regular),
      'pinned': const <dynamic>[],
      'archived': const <dynamic>[],
    };
    final parsed = await _workerManager
        .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
          parseConversationSummariesWorker,
          payload,
          debugLabel: debugLabel,
        );
    return parsed
        .map((json) => Conversation.fromJson(json))
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _normalizeList(
    List<dynamic> raw, {
    required String debugLabel,
  }) {
    return _workerManager
        .schedule<Map<String, dynamic>, List<Map<String, dynamic>>>(
          _normalizeMapListWorker,
          {'list': raw},
          debugLabel: debugLabel,
        );
  }

  // Tools - Check available tools on server
  Future<List<Map<String, dynamic>>> getAvailableTools() async {
    _traceApi('Fetching available tools');
    try {
      final response = await _dio.get('/api/v1/tools/');
      final data = response.data;
      if (data is List) {
        return data.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      _traceApi('Error fetching tools: $e');
    }
    return [];
  }

  // Folders
  Future<List<Map<String, dynamic>>> getFolders() async {
    try {
      final response = await _dio.get('/api/v1/folders/');
      DebugLogger.log(
        'fetch-status',
        scope: 'api/folders',
        data: {'code': response.statusCode},
      );
      DebugLogger.log('fetch-ok', scope: 'api/folders');

      final data = response.data;
      if (data is List) {
        _traceApi('Found ${data.length} folders');
        return data.cast<Map<String, dynamic>>();
      } else {
        DebugLogger.warning(
          'unexpected-type',
          scope: 'api/folders',
          data: {'type': data.runtimeType},
        );
        return [];
      }
    } catch (e) {
      DebugLogger.error('fetch-failed', scope: 'api/folders', error: e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createFolder({
    required String name,
    String? parentId,
  }) async {
    _traceApi('Creating folder: $name');
    final response = await _dio.post(
      '/api/v1/folders/',
      data: {'name': name, if (parentId != null) 'parent_id': parentId},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> updateFolder(String id, {String? name, String? parentId}) async {
    _traceApi('Updating folder: $id');
    // OpenWebUI folder update endpoints:
    // - POST /api/v1/folders/{id}/update          -> rename (FolderForm)
    // - POST /api/v1/folders/{id}/update/parent   -> move parent (FolderParentIdForm)
    if (name != null) {
      await _dio.post('/api/v1/folders/$id/update', data: {'name': name});
    }

    if (parentId != null) {
      await _dio.post(
        '/api/v1/folders/$id/update/parent',
        data: {'parent_id': parentId},
      );
    }
  }

  Future<void> deleteFolder(String id) async {
    _traceApi('Deleting folder: $id');
    await _dio.delete('/api/v1/folders/$id');
  }

  Future<void> moveConversationToFolder(
    String conversationId,
    String? folderId,
  ) async {
    _traceApi('Moving conversation $conversationId to folder $folderId');
    await _dio.post(
      '/api/v1/chats/$conversationId/folder',
      data: {'folder_id': folderId},
    );
  }

  Future<List<Conversation>> getConversationsInFolder(String folderId) async {
    _traceApi('Fetching conversations in folder: $folderId');
    final response = await _dio.get('/api/v1/chats/folder/$folderId');
    final data = response.data;
    if (data is List) {
      return _parseConversationSummaryList(
        data,
        debugLabel: 'parse_folder_$folderId',
      );
    }
    return [];
  }

  // Tags
  Future<List<String>> getConversationTags(String conversationId) async {
    _traceApi('Fetching tags for conversation: $conversationId');
    final response = await _dio.get('/api/v1/chats/$conversationId/tags');
    final data = response.data;
    if (data is List) {
      return data.cast<String>();
    }
    return [];
  }

  Future<void> addTagToConversation(String conversationId, String tag) async {
    _traceApi('Adding tag "$tag" to conversation: $conversationId');
    await _dio.post('/api/v1/chats/$conversationId/tags', data: {'tag': tag});
  }

  Future<void> removeTagFromConversation(
    String conversationId,
    String tag,
  ) async {
    _traceApi('Removing tag "$tag" from conversation: $conversationId');
    await _dio.delete('/api/v1/chats/$conversationId/tags/$tag');
  }

  Future<List<String>> getAllTags() async {
    _traceApi('Fetching all available tags');
    final response = await _dio.get('/api/v1/chats/tags');
    final data = response.data;
    if (data is List) {
      return data.cast<String>();
    }
    return [];
  }

  Future<List<Conversation>> getConversationsByTag(String tag) async {
    _traceApi('Fetching conversations with tag: $tag');
    final response = await _dio.get('/api/v1/chats/tags/$tag');
    final data = response.data;
    if (data is List) {
      return _parseConversationSummaryList(data, debugLabel: 'parse_tag_$tag');
    }
    return [];
  }

  // Files
  Future<String> getFileContent(String fileId) async {
    _traceApi('Fetching file content: $fileId');
    // The Open-WebUI endpoint returns the raw file bytes with appropriate
    // Content-Type headers, not JSON. We must read bytes and base64-encode
    // them for consistent handling across platforms/widgets.
    final response = await _dio.get(
      '/api/v1/files/$fileId/content',
      options: Options(responseType: ResponseType.bytes),
    );

    // Try to determine the mime type from response headers; fallback to text/plain
    final contentType =
        response.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    String mimeType = 'text/plain';
    if (contentType.isNotEmpty) {
      // Strip charset if present
      mimeType = contentType.split(';').first.trim();
    }

    final bytes = response.data is List<int>
        ? (response.data as List<int>)
        : (response.data as Uint8List).toList();

    final base64Data = base64Encode(bytes);

    // For images, return a data URL so UI can render directly; otherwise return raw base64
    if (mimeType.startsWith('image/')) {
      return 'data:$mimeType;base64,$base64Data';
    }

    return base64Data;
  }

  Future<Map<String, dynamic>> getFileInfo(String fileId) async {
    _traceApi('Fetching file info: $fileId');
    final response = await _dio.get('/api/v1/files/$fileId');
    return response.data as Map<String, dynamic>;
  }

  Future<List<FileInfo>> getUserFiles() async {
    _traceApi('Fetching user files');
    final response = await _dio.get('/api/v1/files/');
    final data = response.data;
    if (data is List) {
      final normalized = await _normalizeList(
        data,
        debugLabel: 'parse_file_list',
      );
      return normalized.map(FileInfo.fromJson).toList(growable: false);
    }
    return const [];
  }

  // Enhanced File Operations
  Future<List<FileInfo>> searchFiles({
    String? query,
    String? contentType,
    int? limit,
    int? offset,
  }) async {
    _traceApi('Searching files with query: $query');
    final queryParams = <String, dynamic>{};
    if (query != null) queryParams['q'] = query;
    if (contentType != null) queryParams['content_type'] = contentType;
    if (limit != null) queryParams['limit'] = limit;
    if (offset != null) queryParams['offset'] = offset;

    final response = await _dio.get(
      '/api/v1/files/search',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data is List) {
      final normalized = await _normalizeList(
        data,
        debugLabel: 'parse_file_search',
      );
      return normalized.map(FileInfo.fromJson).toList(growable: false);
    }
    return const [];
  }

  Future<List<FileInfo>> getAllFiles() async {
    _traceApi('Fetching all files (admin)');
    final response = await _dio.get('/api/v1/files/all');
    final data = response.data;
    if (data is List) {
      final normalized = await _normalizeList(
        data,
        debugLabel: 'parse_file_all',
      );
      return normalized.map(FileInfo.fromJson).toList(growable: false);
    }
    return const [];
  }

  Future<String> uploadFileWithProgress(
    String filePath,
    String fileName, {
    Function(int sent, int total)? onProgress,
  }) async {
    _traceApi('Uploading file with progress: $fileName');

    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
    });

    final response = await _dio.post(
      '/api/v1/files/',
      data: formData,
      onSendProgress: onProgress,
    );

    return response.data['id'] as String;
  }

  Future<Map<String, dynamic>> updateFileContent(
    String fileId,
    String content,
  ) async {
    _traceApi('Updating file content: $fileId');
    final response = await _dio.post(
      '/api/v1/files/$fileId/data/content/update',
      data: {'content': content},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<String> getFileHtmlContent(String fileId) async {
    _traceApi('Fetching file HTML content: $fileId');
    final response = await _dio.get('/api/v1/files/$fileId/content/html');
    return response.data as String;
  }

  Future<void> deleteFile(String fileId) async {
    _traceApi('Deleting file: $fileId');
    await _dio.delete('/api/v1/files/$fileId');
  }

  Future<Map<String, dynamic>> updateFileMetadata(
    String fileId, {
    String? filename,
    Map<String, dynamic>? metadata,
  }) async {
    _traceApi('Updating file metadata: $fileId');
    final response = await _dio.put(
      '/api/v1/files/$fileId/metadata',
      data: {
        if (filename != null) 'filename': filename,
        if (metadata != null) 'metadata': metadata,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> processFilesBatch(
    List<String> fileIds, {
    String? operation,
    Map<String, dynamic>? options,
  }) async {
    _traceApi('Processing files batch: ${fileIds.length} files');
    final response = await _dio.post(
      '/api/v1/retrieval/process/files/batch',
      data: {
        'file_ids': fileIds,
        if (operation != null) 'operation': operation,
        if (options != null) 'options': options,
      },
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> getFilesByType(String contentType) async {
    _traceApi('Fetching files by type: $contentType');
    final response = await _dio.get(
      '/api/v1/files/',
      queryParameters: {'content_type': contentType},
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> getFileStats() async {
    _traceApi('Fetching file statistics');
    final response = await _dio.get('/api/v1/files/stats');
    return response.data as Map<String, dynamic>;
  }

  // Knowledge Base
  Future<List<KnowledgeBase>> getKnowledgeBases() async {
    _traceApi('Fetching knowledge bases');
    final response = await _dio.get('/api/v1/knowledge/');
    final data = response.data;
    if (data is List) {
      final normalized = await _normalizeList(
        data,
        debugLabel: 'parse_knowledge_bases',
      );
      return normalized.map(KnowledgeBase.fromJson).toList(growable: false);
    }
    return const [];
  }

  Future<Map<String, dynamic>> createKnowledgeBase({
    required String name,
    String? description,
  }) async {
    _traceApi('Creating knowledge base: $name');
    final response = await _dio.post(
      '/api/v1/knowledge/',
      data: {'name': name, if (description != null) 'description': description},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> updateKnowledgeBase(
    String id, {
    String? name,
    String? description,
  }) async {
    _traceApi('Updating knowledge base: $id');
    await _dio.put(
      '/api/v1/knowledge/$id',
      data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
      },
    );
  }

  Future<void> deleteKnowledgeBase(String id) async {
    _traceApi('Deleting knowledge base: $id');
    await _dio.delete('/api/v1/knowledge/$id');
  }

  Future<List<KnowledgeBaseItem>> getKnowledgeBaseItems(
    String knowledgeBaseId,
  ) async {
    _traceApi('Fetching knowledge base items: $knowledgeBaseId');
    final response = await _dio.get('/api/v1/knowledge/$knowledgeBaseId/items');
    final data = response.data;
    if (data is List) {
      final normalized = await _normalizeList(
        data,
        debugLabel: 'parse_kb_items',
      );
      return normalized.map(KnowledgeBaseItem.fromJson).toList(growable: false);
    }
    return const [];
  }

  Future<Map<String, dynamic>> addKnowledgeBaseItem(
    String knowledgeBaseId, {
    required String content,
    String? title,
    Map<String, dynamic>? metadata,
  }) async {
    _traceApi('Adding item to knowledge base: $knowledgeBaseId');
    final response = await _dio.post(
      '/api/v1/knowledge/$knowledgeBaseId/items',
      data: {
        'content': content,
        if (title != null) 'title': title,
        if (metadata != null) 'metadata': metadata,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> searchKnowledgeBase(
    String knowledgeBaseId,
    String query,
  ) async {
    _traceApi('Searching knowledge base: $knowledgeBaseId for: $query');
    final response = await _dio.post(
      '/api/v1/knowledge/$knowledgeBaseId/search',
      data: {'query': query},
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  // Web Search
  Future<Map<String, dynamic>> performWebSearch(List<String> queries) async {
    _traceApi('Performing web search for queries: $queries');
    try {
      final response = await _dio.post(
        '/api/v1/retrieval/process/web/search',
        data: {'queries': queries},
      );

      DebugLogger.log(
        'status',
        scope: 'api/web-search',
        data: {'code': response.statusCode},
      );
      DebugLogger.log(
        'response-type',
        scope: 'api/web-search',
        data: {'type': response.data.runtimeType},
      );
      DebugLogger.log('fetch-ok', scope: 'api/web-search');

      return response.data as Map<String, dynamic>;
    } catch (e) {
      _traceApi('Web search API error: $e');
      if (e is DioException) {
        DebugLogger.error('error-response', scope: 'api/web-search', error: e);
        _traceApi('Web search error status: ${e.response?.statusCode}');
      }
      rethrow;
    }
  }

  // Get detailed model information
  Future<Map<String, dynamic>?> getModelDetails(String modelId) async {
    try {
      final response = await _dio.get(
        '/api/v1/models/model',
        queryParameters: {'id': modelId},
      );

      if (response.statusCode == 200 && response.data != null) {
        final modelData = response.data as Map<String, dynamic>;
        DebugLogger.log('details', scope: 'api/models', data: {'id': modelId});
        return modelData;
      }
    } catch (e) {
      _traceApi('Failed to get model details for $modelId: $e');
    }
    return null;
  }

  // Send chat completed notification
  Future<void> sendChatCompleted({
    required String chatId,
    required String messageId,
    required List<Map<String, dynamic>> messages,
    required String model,
    Map<String, dynamic>? modelItem,
    String? sessionId,
  }) async {
    _traceApi('Sending chat completed notification (optional endpoint)');

    // This endpoint appears to be optional or deprecated in newer OpenWebUI versions
    // The main chat synchronization happens through /api/v1/chats/{id} updates
    // We'll still try to call it but won't fail if it doesn't work

    // Format messages to match OpenWebUI expected structure
    // Note: Removing 'id' field as it causes 400 error
    final formattedMessages = messages.map((msg) {
      final formatted = {
        // Don't include 'id' - it causes 400 error with detail: 'id'
        'role': msg['role'],
        'content': msg['content'],
        'timestamp':
            msg['timestamp'] ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };

      // Add model info for assistant messages
      if (msg['role'] == 'assistant') {
        formatted['model'] = model;
        if (msg.containsKey('usage')) {
          formatted['usage'] = msg['usage'];
        }
      }

      return formatted;
    }).toList();

    // Include the message ID and session ID at the top level - server expects these
    final requestData = {
      'id': messageId, // The server expects the assistant message ID here
      'chat_id': chatId,
      'model': model,
      'messages': formattedMessages,
      'session_id':
          sessionId ?? const Uuid().v4().substring(0, 20), // Add session_id
      // Don't include model_item as it might not be expected
    };

    try {
      final response = await _dio.post(
        '/api/chat/completed',
        data: requestData,
        options: Options(
          sendTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 4),
        ),
      );
      _traceApi('Chat completed response: ${response.statusCode}');
    } catch (e) {
      // This is a non-critical endpoint - main sync happens via /api/v1/chats/{id}
      _traceApi(
        'Chat completed endpoint not available or failed (non-critical): $e',
      );
    }
  }

  // Query a collection for content
  Future<List<dynamic>> queryCollection(
    String collectionName,
    String query,
  ) async {
    _traceApi('Querying collection: $collectionName with query: $query');
    try {
      final response = await _dio.post(
        '/api/v1/retrieval/query/collection',
        data: {
          'collection_names': [collectionName], // API expects an array
          'query': query,
          'k': 5, // Limit to top 5 results
        },
      );

      _traceApi('Collection query response status: ${response.statusCode}');
      _traceApi('Collection query response type: ${response.data.runtimeType}');
      DebugLogger.log(
        'query-ok',
        scope: 'api/collection',
        data: {'name': collectionName},
      );

      if (response.data is List) {
        return response.data as List<dynamic>;
      } else if (response.data is Map<String, dynamic>) {
        // If the response is a map, check for common result keys
        final data = response.data as Map<String, dynamic>;
        if (data.containsKey('results')) {
          return data['results'] as List<dynamic>? ?? [];
        } else if (data.containsKey('documents')) {
          return data['documents'] as List<dynamic>? ?? [];
        } else if (data.containsKey('data')) {
          return data['data'] as List<dynamic>? ?? [];
        }
      }

      return [];
    } catch (e) {
      _traceApi('Collection query API error: $e');
      if (e is DioException) {
        _traceApi('Collection query error response: ${e.response?.data}');
        _traceApi('Collection query error status: ${e.response?.statusCode}');
      }
      rethrow;
    }
  }

  // Get retrieval configuration to check web search settings
  Future<Map<String, dynamic>> getRetrievalConfig() async {
    _traceApi('Getting retrieval configuration');
    try {
      final response = await _dio.get('/api/v1/retrieval/config');

      _traceApi('Retrieval config response status: ${response.statusCode}');
      DebugLogger.log('config-ok', scope: 'api/retrieval');

      return response.data as Map<String, dynamic>;
    } catch (e) {
      _traceApi('Retrieval config API error: $e');
      if (e is DioException) {
        _traceApi('Retrieval config error response: ${e.response?.data}');
        _traceApi('Retrieval config error status: ${e.response?.statusCode}');
      }
      rethrow;
    }
  }

  // Audio
  Future<String?> getDefaultServerVoice() async {
    _traceApi('Fetching default server TTS voice');
    final response = await _dio.get('/api/v1/audio/config');
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final ttsConfig = data['tts'];
      if (ttsConfig is Map<String, dynamic>) {
        final voice = ttsConfig['VOICE'] ?? ttsConfig['voice'];
        if (voice is String && voice.trim().isNotEmpty) {
          return voice.trim();
        }
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> getAvailableServerVoices() async {
    _traceApi('Fetching server TTS voices');
    final response = await _dio.get('/api/v1/audio/voices');
    final data = response.data;
    if (data is Map<String, dynamic>) {
      final voices = data['voices'];
      if (voices is List) {
        return _normalizeList(voices, debugLabel: 'parse_voice_list');
      }
    }
    if (data is List) {
      // Fallback: plain list of ids
      return data
          .map((e) => {'id': e.toString(), 'name': e.toString()})
          .toList();
    }
    return [];
  }

  Future<Map<String, dynamic>> transcribeSpeech({
    required Uint8List audioBytes,
    String? fileName,
    String? mimeType,
    String? language,
  }) async {
    if (audioBytes.isEmpty) {
      throw ArgumentError('audioBytes cannot be empty for transcription');
    }

    final sanitizedFileName = (fileName != null && fileName.trim().isNotEmpty
        ? fileName.trim()
        : 'audio.m4a');
    final resolvedMimeType = (mimeType != null && mimeType.trim().isNotEmpty)
        ? mimeType.trim()
        : _inferMimeTypeFromName(sanitizedFileName);

    _traceApi(
      'Uploading $sanitizedFileName (${audioBytes.length} bytes) for transcription',
    );

    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        audioBytes,
        filename: sanitizedFileName,
        contentType: _parseMediaType(resolvedMimeType),
      ),
      if (language != null && language.trim().isNotEmpty)
        'language': language.trim(),
    });

    final response = await _dio.post(
      '/api/v1/audio/transcriptions',
      data: formData,
      options: Options(headers: const {'accept': 'application/json'}),
    );

    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is String) {
      return {'text': data};
    }
    throw StateError(
      'Unexpected transcription response type: ${data.runtimeType}',
    );
  }

  Future<({Uint8List bytes, String mimeType})> generateSpeech({
    required String text,
    String? voice,
    double? speed,
  }) async {
    final textPreview = text.length > 50 ? text.substring(0, 50) : text;
    _traceApi('Generating speech for text: $textPreview...');
    final response = await _dio.post(
      '/api/v1/audio/speech',
      data: {
        'input': text,
        if (voice != null) 'voice': voice,
        if (speed != null) 'speed': speed,
      },
      options: Options(responseType: ResponseType.bytes),
    );

    final rawMimeType = response.headers.value('content-type');
    final audioBytes = _coerceAudioBytes(response.data);
    final resolvedMimeType = _resolveAudioMimeType(rawMimeType, audioBytes);

    return (bytes: audioBytes, mimeType: resolvedMimeType);
  }

  Uint8List _coerceAudioBytes(Object? data) {
    if (data is Uint8List && data.isNotEmpty) {
      return Uint8List.fromList(data);
    }
    if (data is List<int>) {
      return Uint8List.fromList(data);
    }
    if (data is List) {
      return Uint8List.fromList(data.cast<int>());
    }
    return Uint8List(0);
  }

  String _resolveAudioMimeType(String? rawMimeType, Uint8List bytes) {
    final sanitized = rawMimeType?.split(';').first.trim();
    if (sanitized != null && sanitized.isNotEmpty) {
      return sanitized;
    }
    if (_matchesPrefix(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
        _matchesPrefix(bytes, const [0x57, 0x41, 0x56, 0x45], offset: 8)) {
      return 'audio/wav';
    }
    if (_matchesPrefix(bytes, const [0x4F, 0x67, 0x67, 0x53])) {
      return 'audio/ogg';
    }
    if (_matchesPrefix(bytes, const [0x66, 0x4C, 0x61, 0x43])) {
      return 'audio/flac';
    }
    if (_looksLikeMp4(bytes)) {
      return 'audio/mp4';
    }
    if (_looksLikeMpeg(bytes)) {
      return 'audio/mpeg';
    }
    return 'audio/mpeg';
  }

  bool _matchesPrefix(Uint8List bytes, List<int> signature, {int offset = 0}) {
    if (bytes.length < offset + signature.length) {
      return false;
    }
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) {
        return false;
      }
    }
    return true;
  }

  bool _looksLikeMp4(Uint8List bytes) {
    return bytes.length >= 8 &&
        _matchesPrefix(bytes, const [0x66, 0x74, 0x79, 0x70], offset: 4);
  }

  bool _looksLikeMpeg(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0x49 &&
        bytes[1] == 0x44 &&
        bytes[2] == 0x33) {
      return true;
    }
    return bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
  }

  String _inferMimeTypeFromName(String name) {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == name.length - 1) {
      return 'audio/mpeg';
    }
    final ext = name.substring(dotIndex + 1).toLowerCase();
    switch (ext) {
      case 'wav':
        return 'audio/wav';
      case 'ogg':
        return 'audio/ogg';
      case 'm4a':
      case 'mp4':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'webm':
        return 'audio/webm';
      case 'flac':
        return 'audio/flac';
      case 'mp3':
        return 'audio/mpeg';
      default:
        return 'audio/mpeg';
    }
  }

  MediaType? _parseMediaType(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    try {
      return MediaType.parse(value);
    } catch (_) {
      return null;
    }
  }

  // Image Generation
  Future<List<Map<String, dynamic>>> getImageModels() async {
    _traceApi('Fetching image generation models');
    final response = await _dio.get('/api/v1/images/models');
    final data = response.data;
    if (data is List) {
      return _normalizeList(data, debugLabel: 'parse_image_models');
    }
    return [];
  }

  Future<dynamic> generateImage({
    required String prompt,
    String? model,
    int? width,
    int? height,
    int? steps,
    double? guidance,
  }) async {
    final promptPreview = prompt.length > 50 ? prompt.substring(0, 50) : prompt;
    _traceApi('Generating image with prompt: $promptPreview...');
    try {
      final response = await _dio.post(
        '/api/v1/images/generations',
        data: {
          'prompt': prompt,
          if (model != null) 'model': model,
          if (width != null) 'width': width,
          if (height != null) 'height': height,
          if (steps != null) 'steps': steps,
          if (guidance != null) 'guidance': guidance,
        },
      );
      return response.data;
    } on DioException catch (e) {
      _traceApi('images/generations failed: ${e.response?.statusCode}');
      DebugLogger.error(
        'images-generate-failed',
        scope: 'api/images',
        error: e,
        data: {'status': e.response?.statusCode},
      );
      // Do not attempt singular fallback here - surface the original error
      rethrow;
    }
  }

  // Prompts
  Future<List<Prompt>> getPrompts() async {
    _traceApi('Fetching prompts');
    final response = await _dio.get('/api/v1/prompts/');
    final data = response.data;
    if (data is List) {
      final normalized = await _normalizeList(
        data,
        debugLabel: 'parse_prompts',
      );
      return normalized
          .map(Prompt.fromJson)
          .where((prompt) => prompt.command.isNotEmpty)
          .toList(growable: false);
    }
    return const [];
  }

  // Permissions & Features
  Future<Map<String, dynamic>> getUserPermissions() async {
    _traceApi('Fetching user permissions');
    try {
      final response = await _dio.get('/api/v1/users/permissions');
      return response.data as Map<String, dynamic>;
    } catch (e) {
      _traceApi('Error fetching user permissions: $e');
      if (e is DioException) {
        _traceApi('Permissions error response: ${e.response?.data}');
        _traceApi('Permissions error status: ${e.response?.statusCode}');
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createPrompt({
    required String title,
    required String content,
    String? description,
    List<String>? tags,
  }) async {
    _traceApi('Creating prompt: $title');
    final response = await _dio.post(
      '/api/v1/prompts/',
      data: {
        'title': title,
        'content': content,
        if (description != null) 'description': description,
        if (tags != null) 'tags': tags,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> updatePrompt(
    String id, {
    String? title,
    String? content,
    String? description,
    List<String>? tags,
  }) async {
    _traceApi('Updating prompt: $id');
    await _dio.put(
      '/api/v1/prompts/$id',
      data: {
        if (title != null) 'title': title,
        if (content != null) 'content': content,
        if (description != null) 'description': description,
        if (tags != null) 'tags': tags,
      },
    );
  }

  Future<void> deletePrompt(String id) async {
    _traceApi('Deleting prompt: $id');
    await _dio.delete('/api/v1/prompts/$id');
  }

  // Tools & Functions
  Future<List<Map<String, dynamic>>> getTools() async {
    _traceApi('Fetching tools');
    final response = await _dio.get('/api/v1/tools/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> getFunctions() async {
    _traceApi('Fetching functions');
    final response = await _dio.get('/api/v1/functions/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> createTool({
    required String name,
    required Map<String, dynamic> spec,
  }) async {
    _traceApi('Creating tool: $name');
    final response = await _dio.post(
      '/api/v1/tools/',
      data: {'name': name, 'spec': spec},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createFunction({
    required String name,
    required String code,
    String? description,
  }) async {
    _traceApi('Creating function: $name');
    final response = await _dio.post(
      '/api/v1/functions/',
      data: {
        'name': name,
        'code': code,
        if (description != null) 'description': description,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  // Enhanced Tools Management Operations
  Future<Map<String, dynamic>> getTool(String toolId) async {
    _traceApi('Fetching tool details: $toolId');
    final response = await _dio.get('/api/v1/tools/id/$toolId');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateTool(
    String toolId, {
    String? name,
    Map<String, dynamic>? spec,
    String? description,
  }) async {
    _traceApi('Updating tool: $toolId');
    final response = await _dio.post(
      '/api/v1/tools/id/$toolId/update',
      data: {
        if (name != null) 'name': name,
        if (spec != null) 'spec': spec,
        if (description != null) 'description': description,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> deleteTool(String toolId) async {
    _traceApi('Deleting tool: $toolId');
    await _dio.delete('/api/v1/tools/id/$toolId/delete');
  }

  Future<Map<String, dynamic>> getToolValves(String toolId) async {
    _traceApi('Fetching tool valves: $toolId');
    final response = await _dio.get('/api/v1/tools/id/$toolId/valves');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateToolValves(
    String toolId,
    Map<String, dynamic> valves,
  ) async {
    _traceApi('Updating tool valves: $toolId');
    final response = await _dio.post(
      '/api/v1/tools/id/$toolId/valves/update',
      data: valves,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getUserToolValves(String toolId) async {
    _traceApi('Fetching user tool valves: $toolId');
    final response = await _dio.get('/api/v1/tools/id/$toolId/valves/user');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateUserToolValves(
    String toolId,
    Map<String, dynamic> valves,
  ) async {
    _traceApi('Updating user tool valves: $toolId');
    final response = await _dio.post(
      '/api/v1/tools/id/$toolId/valves/user/update',
      data: valves,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> exportTools() async {
    _traceApi('Exporting tools configuration');
    final response = await _dio.get('/api/v1/tools/export');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> loadToolFromUrl(String url) async {
    _traceApi('Loading tool from URL: $url');
    final response = await _dio.post(
      '/api/v1/tools/load/url',
      data: {'url': url},
    );
    return response.data as Map<String, dynamic>;
  }

  // Enhanced Functions Management Operations
  Future<Map<String, dynamic>> getFunction(String functionId) async {
    _traceApi('Fetching function details: $functionId');
    final response = await _dio.get('/api/v1/functions/id/$functionId');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateFunction(
    String functionId, {
    String? name,
    String? code,
    String? description,
  }) async {
    _traceApi('Updating function: $functionId');
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/update',
      data: {
        if (name != null) 'name': name,
        if (code != null) 'code': code,
        if (description != null) 'description': description,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> deleteFunction(String functionId) async {
    _traceApi('Deleting function: $functionId');
    await _dio.delete('/api/v1/functions/id/$functionId/delete');
  }

  Future<Map<String, dynamic>> toggleFunction(String functionId) async {
    _traceApi('Toggling function: $functionId');
    final response = await _dio.post('/api/v1/functions/id/$functionId/toggle');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> toggleGlobalFunction(String functionId) async {
    _traceApi('Toggling global function: $functionId');
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/toggle/global',
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getFunctionValves(String functionId) async {
    _traceApi('Fetching function valves: $functionId');
    final response = await _dio.get('/api/v1/functions/id/$functionId/valves');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateFunctionValves(
    String functionId,
    Map<String, dynamic> valves,
  ) async {
    _traceApi('Updating function valves: $functionId');
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/valves/update',
      data: valves,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getUserFunctionValves(String functionId) async {
    _traceApi('Fetching user function valves: $functionId');
    final response = await _dio.get(
      '/api/v1/functions/id/$functionId/valves/user',
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateUserFunctionValves(
    String functionId,
    Map<String, dynamic> valves,
  ) async {
    _traceApi('Updating user function valves: $functionId');
    final response = await _dio.post(
      '/api/v1/functions/id/$functionId/valves/user/update',
      data: valves,
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> syncFunctions() async {
    _traceApi('Syncing functions');
    final response = await _dio.post('/api/v1/functions/sync');
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> exportFunctions() async {
    _traceApi('Exporting functions configuration');
    final response = await _dio.get('/api/v1/functions/export');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  // Memory & Notes
  Future<List<Map<String, dynamic>>> getMemories() async {
    _traceApi('Fetching memories');
    final response = await _dio.get('/api/v1/memories/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> createMemory({
    required String content,
    String? title,
  }) async {
    _traceApi('Creating memory');
    final response = await _dio.post(
      '/api/v1/memories/',
      data: {'content': content, if (title != null) 'title': title},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getNotes() async {
    _traceApi('Fetching notes');
    final response = await _dio.get('/api/v1/notes/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> createNote({
    required String title,
    required String content,
    List<String>? tags,
  }) async {
    _traceApi('Creating note: $title');
    final response = await _dio.post(
      '/api/v1/notes/',
      data: {
        'title': title,
        'content': content,
        if (tags != null) 'tags': tags,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> updateNote(
    String id, {
    String? title,
    String? content,
    List<String>? tags,
  }) async {
    _traceApi('Updating note: $id');
    await _dio.put(
      '/api/v1/notes/$id',
      data: {
        if (title != null) 'title': title,
        if (content != null) 'content': content,
        if (tags != null) 'tags': tags,
      },
    );
  }

  Future<void> deleteNote(String id) async {
    _traceApi('Deleting note: $id');
    await _dio.delete('/api/v1/notes/$id');
  }

  // Team Collaboration
  Future<List<Map<String, dynamic>>> getChannels() async {
    _traceApi('Fetching channels');
    final response = await _dio.get('/api/v1/channels/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> createChannel({
    required String name,
    String? description,
    bool isPrivate = false,
  }) async {
    _traceApi('Creating channel: $name');
    final response = await _dio.post(
      '/api/v1/channels/',
      data: {
        'name': name,
        if (description != null) 'description': description,
        'is_private': isPrivate,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> joinChannel(String channelId) async {
    _traceApi('Joining channel: $channelId');
    await _dio.post('/api/v1/channels/$channelId/join');
  }

  Future<void> leaveChannel(String channelId) async {
    _traceApi('Leaving channel: $channelId');
    await _dio.post('/api/v1/channels/$channelId/leave');
  }

  Future<List<Map<String, dynamic>>> getChannelMembers(String channelId) async {
    _traceApi('Fetching channel members: $channelId');
    final response = await _dio.get('/api/v1/channels/$channelId/members');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<List<Conversation>> getChannelConversations(String channelId) async {
    _traceApi('Fetching channel conversations: $channelId');
    final response = await _dio.get('/api/v1/channels/$channelId/chats');
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((chatData) {
        final map = Map<String, dynamic>.from(chatData);
        return Conversation.fromJson(parseConversationSummary(map));
      }).toList();
    }
    return [];
  }

  // Enhanced Channel Management Operations
  Future<Map<String, dynamic>> getChannel(String channelId) async {
    _traceApi('Fetching channel details: $channelId');
    final response = await _dio.get('/api/v1/channels/$channelId');
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateChannel(
    String channelId, {
    String? name,
    String? description,
    bool? isPrivate,
  }) async {
    _traceApi('Updating channel: $channelId');
    final response = await _dio.post(
      '/api/v1/channels/$channelId/update',
      data: {
        if (name != null) 'name': name,
        if (description != null) 'description': description,
        if (isPrivate != null) 'is_private': isPrivate,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> deleteChannel(String channelId) async {
    _traceApi('Deleting channel: $channelId');
    await _dio.delete('/api/v1/channels/$channelId/delete');
  }

  Future<List<Map<String, dynamic>>> getChannelMessages(
    String channelId, {
    int? limit,
    int? offset,
    DateTime? before,
    DateTime? after,
  }) async {
    _traceApi('Fetching channel messages: $channelId');
    final queryParams = <String, dynamic>{};
    if (limit != null) queryParams['limit'] = limit;
    if (offset != null) queryParams['offset'] = offset;
    if (before != null) queryParams['before'] = before.toIso8601String();
    if (after != null) queryParams['after'] = after.toIso8601String();

    final response = await _dio.get(
      '/api/v1/channels/$channelId/messages',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> postChannelMessage(
    String channelId, {
    required String content,
    String? messageType,
    Map<String, dynamic>? metadata,
  }) async {
    _traceApi('Posting message to channel: $channelId');
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages/post',
      data: {
        'content': content,
        if (messageType != null) 'message_type': messageType,
        if (metadata != null) 'metadata': metadata,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateChannelMessage(
    String channelId,
    String messageId, {
    String? content,
    Map<String, dynamic>? metadata,
  }) async {
    _traceApi('Updating channel message: $channelId/$messageId');
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages/$messageId/update',
      data: {
        if (content != null) 'content': content,
        if (metadata != null) 'metadata': metadata,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> deleteChannelMessage(String channelId, String messageId) async {
    _traceApi('Deleting channel message: $channelId/$messageId');
    await _dio.delete('/api/v1/channels/$channelId/messages/$messageId');
  }

  Future<Map<String, dynamic>> addMessageReaction(
    String channelId,
    String messageId,
    String emoji,
  ) async {
    _traceApi('Adding reaction to message: $channelId/$messageId');
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages/$messageId/reactions',
      data: {'emoji': emoji},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> removeMessageReaction(
    String channelId,
    String messageId,
    String emoji,
  ) async {
    _traceApi('Removing reaction from message: $channelId/$messageId');
    await _dio.delete(
      '/api/v1/channels/$channelId/messages/$messageId/reactions/$emoji',
    );
  }

  Future<List<Map<String, dynamic>>> getMessageReactions(
    String channelId,
    String messageId,
  ) async {
    _traceApi('Fetching message reactions: $channelId/$messageId');
    final response = await _dio.get(
      '/api/v1/channels/$channelId/messages/$messageId/reactions',
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> getMessageThread(
    String channelId,
    String messageId,
  ) async {
    _traceApi('Fetching message thread: $channelId/$messageId');
    final response = await _dio.get(
      '/api/v1/channels/$channelId/messages/$messageId/thread',
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<Map<String, dynamic>> replyToMessage(
    String channelId,
    String messageId, {
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    _traceApi('Replying to message: $channelId/$messageId');
    final response = await _dio.post(
      '/api/v1/channels/$channelId/messages/$messageId/reply',
      data: {'content': content, if (metadata != null) 'metadata': metadata},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<void> markChannelRead(String channelId, {String? messageId}) async {
    _traceApi('Marking channel as read: $channelId');
    await _dio.post(
      '/api/v1/channels/$channelId/read',
      data: {if (messageId != null) 'last_read_message_id': messageId},
    );
  }

  Future<Map<String, dynamic>> getChannelUnreadCount(String channelId) async {
    _traceApi('Fetching unread count for channel: $channelId');
    final response = await _dio.get('/api/v1/channels/$channelId/unread');
    return response.data as Map<String, dynamic>;
  }

  // Chat streaming with conversation context
  // Track cancellable streaming requests by messageId for stop parity
  final Map<String, CancelToken> _streamCancelTokens = {};
  final Map<String, String> _messagePersistentStreamIds = {};

  /// Associates a streaming message with its persistent stream identifier.
  void registerPersistentStreamForMessage(String messageId, String streamId) {
    _messagePersistentStreamIds[messageId] = streamId;
  }

  /// Removes the persistent stream mapping for a message if it matches.
  ///
  /// Returns the removed persistent stream identifier when one existed and
  /// matched the optional [expectedStreamId].
  String? clearPersistentStreamForMessage(
    String messageId, {
    String? expectedStreamId,
  }) {
    final current = _messagePersistentStreamIds[messageId];
    if (current == null) {
      return null;
    }
    if (expectedStreamId != null && current != expectedStreamId) {
      return null;
    }
    return _messagePersistentStreamIds.remove(messageId);
  }

  // Send message using dual-stream approach (HTTP SSE + WebSocket events).
  // Matches OpenWebUI web client behavior:
  // - HTTP SSE stream provides immediate content chunks
  // - WebSocket events deliver metadata, tool status, sources, follow-ups
  // - Both streams run in parallel for reliability
  // Returns a record with (stream, messageId, sessionId, socketSessionId, isBackgroundFlow)
  ({
    Stream<String> stream,
    String messageId,
    String sessionId,
    String? socketSessionId,
    bool isBackgroundFlow,
  })
  sendMessage({
    required List<Map<String, dynamic>> messages,
    required String model,
    String? conversationId,
    List<String>? toolIds,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    Map<String, dynamic>? modelItem,
    String? sessionIdOverride,
    String? socketSessionId,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    String? responseMessageId,
    Map<String, dynamic>? userSettings,
  }) {
    final streamController = StreamController<String>();

    // Generate unique IDs
    final messageId =
        (responseMessageId != null && responseMessageId.isNotEmpty)
        ? responseMessageId
        : const Uuid().v4();
    final sessionId =
        (sessionIdOverride != null && sessionIdOverride.isNotEmpty)
        ? sessionIdOverride
        : const Uuid().v4().substring(0, 20);

    // NOTE: Previously used to branch for Gemini-specific handling; not needed now.

    // Process messages to match OpenWebUI format
    final processedMessages = messages.map((message) {
      final role = message['role'] as String;
      final content = message['content'];
      final files = message['files'] as List<Map<String, dynamic>>?;

      final isContentArray = content is List;
      final hasImages = files?.any((file) => file['type'] == 'image') ?? false;

      if (isContentArray) {
        return {'role': role, 'content': content};
      } else if (hasImages && role == 'user') {
        final imageFiles = files!
            .where((file) => file['type'] == 'image')
            .toList();
        final contentText = content is String ? content : '';
        final contentArray = <Map<String, dynamic>>[
          {'type': 'text', 'text': contentText},
        ];

        for (final file in imageFiles) {
          contentArray.add({
            'type': 'image_url',
            'image_url': {'url': file['url']},
          });
        }
        return {'role': role, 'content': contentArray};
      } else {
        final contentText = content is String ? content : '';
        return {'role': role, 'content': contentText};
      }
    }).toList();

    // Separate files from messages
    final allFiles = <Map<String, dynamic>>[];
    for (final message in messages) {
      final files = message['files'] as List<Map<String, dynamic>>?;
      if (files != null) {
        final nonImageFiles = files
            .where((file) => file['type'] != 'image')
            .toList();
        allFiles.addAll(nonImageFiles);
      }
    }

    final bool hasBackgroundTasksPayload =
        backgroundTasks != null && backgroundTasks.isNotEmpty;

    // Build request data. Always request streamed responses so the backend can
    // forward deltas over WebSocket when running in background task mode.
    final data = <String, dynamic>{
      'stream': true,
      'model': model,
      'messages': processedMessages,
    };

    // Add only essential parameters
    if (conversationId != null) {
      data['chat_id'] = conversationId;
    }

    // Add feature flags if enabled
    if (enableWebSearch) {
      data['web_search'] = true;
      _traceApi('Web search enabled in streaming request');
    }
    if (enableImageGeneration) {
      // Mirror web_search behavior for image generation
      data['image_generation'] = true;
      _traceApi('Image generation enabled in streaming request');
    }

    if (enableWebSearch || enableImageGeneration) {
      // Include features map for compatibility
      data['features'] = {
        'web_search': enableWebSearch,
        'image_generation': enableImageGeneration,
        'code_interpreter': false,
        'memory': false,
      };
    }

    data['id'] = messageId;

    // No default reasoning parameters included; providers handle thinking UIs natively.

    // Add tool_ids if provided (Open-WebUI expects tool_ids as array of strings)
    if (toolIds != null && toolIds.isNotEmpty) {
      data['tool_ids'] = toolIds;
      _traceApi('Including tool_ids in streaming request: $toolIds');

      // Respect user's function_calling preference from backend settings
      // If not set, backend will default to 'default' mode (safer, more compatible)
      try {
        final userParams = userSettings?['params'] as Map<String, dynamic>?;
        final functionCallingMode = userParams?['function_calling'] as String?;

        if (functionCallingMode != null) {
          final params =
              (data['params'] as Map<String, dynamic>?) ?? <String, dynamic>{};
          params['function_calling'] = functionCallingMode;
          data['params'] = params;
          _traceApi(
            'Set params.function_calling = $functionCallingMode (from user settings)',
          );
        } else {
          _traceApi(
            'No function_calling preference in user settings, backend will use default mode',
          );
        }
      } catch (_) {
        // Non-fatal; continue without setting function_calling mode
      }
    }

    // Include tool_servers if provided (for native function calling with OpenAPI servers)
    if (toolServers != null && toolServers.isNotEmpty) {
      data['tool_servers'] = toolServers;
      _traceApi('Including tool_servers in request (${toolServers.length})');
    }

    // Include non-image files at the top level as expected by Open WebUI
    if (allFiles.isNotEmpty) {
      data['files'] = allFiles;
      _traceApi('Including non-image files in request: ${allFiles.length}');
    }

    _traceApi('Preparing dual-stream chat request (HTTP SSE + WebSocket)');
    _traceApi('Model: $model');
    _traceApi('Message count: ${processedMessages.length}');

    // Debug the data being sent
    _traceApi('Request data keys (pre-dispatch): ${data.keys.toList()}');
    _traceApi('Has background_tasks: ${data.containsKey('background_tasks')}');
    _traceApi('Has session_id: ${data.containsKey('session_id')}');
    _traceApi('background_tasks value: ${data['background_tasks']}');
    _traceApi('session_id value: ${data['session_id']}');
    _traceApi('id value: ${data['id']}');

    _traceApi(
      'Request features: hasBackgroundTasks=$hasBackgroundTasksPayload, '
      'tools=${toolIds?.isNotEmpty == true}, '
      'webSearch=$enableWebSearch, imageGen=$enableImageGeneration, '
      'toolServers=${toolServers?.isNotEmpty == true}',
    );

    // Attach identifiers to trigger background task processing on the server
    data['session_id'] = sessionId;
    data['id'] = messageId;
    if (conversationId != null) {
      data['chat_id'] = conversationId;
    }

    // Attach background_tasks if provided
    if (backgroundTasks != null && backgroundTasks.isNotEmpty) {
      data['background_tasks'] = backgroundTasks;
    }

    // Extra diagnostics to confirm dynamic-channel payload
    _traceApi('Background flow payload keys: ${data.keys.toList()}');
    _traceApi('Using session_id: $sessionId');
    _traceApi('Using message id: $messageId');
    _traceApi(
      'Has tool_ids: ${data.containsKey('tool_ids')} -> ${data['tool_ids']}',
    );
    _traceApi('Has background_tasks: ${data.containsKey('background_tasks')}');

    _traceApi('Initiating dual-stream request (HTTP SSE + WebSocket)');
    _traceApi('Posting to /api/chat/completions');

    // Create a cancel token for this request
    final cancelToken = CancelToken();
    _streamCancelTokens[messageId] = cancelToken;

    // Start HTTP SSE stream (matches web client behavior)
    // The WebSocket events will run in parallel via streaming_helper.dart
    () async {
      try {
        final resp = await _dio.post(
          '/api/chat/completions',
          data: data,
          options: Options(
            responseType: ResponseType.stream,
            // Extended timeout for streaming responses - allow up to 10 minutes
            // for long-running tool calls and reasoning
            receiveTimeout: const Duration(minutes: 10),
            // Shorter send timeout for the initial request
            sendTimeout: const Duration(seconds: 30),
            headers: {
              'Accept': 'text/event-stream',
              // Enable HTTP keep-alive to maintain connection in background
              'Connection': 'keep-alive',
              // Request server to send keep-alive messages
              'Cache-Control': 'no-cache',
            },
          ),
          cancelToken: cancelToken,
        );

        final respData = resp.data;

        // Check if we got a task_id response (non-streaming)
        if (respData is Map && respData['task_id'] != null) {
          final taskId = respData['task_id'].toString();
          _traceApi('Background task created: $taskId');

          // In this case, all streaming will happen via WebSocket
          // Close HTTP stream but keep WebSocket active
          if (!streamController.isClosed) {
            streamController.close();
          }
          return;
        }

        // We have a streaming response body
        if (respData is ResponseBody) {
          _traceApi('HTTP SSE stream started for message: $messageId');

          // Parse SSE stream and forward chunks to controller
          await for (final chunk in SSEStreamParser.parseResponseStream(
            respData,
            splitLargeDeltas: false,
            heartbeatTimeout: const Duration(minutes: 2),
            onHeartbeat: () {
              // Notify persistent streaming service that connection is alive
              final persistentStreamId = _messagePersistentStreamIds[messageId];
              if (persistentStreamId != null) {
                PersistentStreamingService().updateStreamProgress(
                  persistentStreamId,
                  chunkSequence: DateTime.now().millisecondsSinceEpoch,
                );
              }
            },
          )) {
            if (!streamController.isClosed) {
              streamController.add(chunk);
            } else {
              _traceApi('Stream controller closed, stopping SSE parsing');
              break;
            }
          }

          _traceApi('HTTP SSE stream completed for message: $messageId');
        } else {
          _traceApi('Unexpected response type: ${respData.runtimeType}');
        }

        // Close the HTTP stream controller
        // WebSocket events will continue independently via streaming_helper
        if (!streamController.isClosed) {
          streamController.close();
        }
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          _traceApi('HTTP stream cancelled for message: $messageId');
        } else {
          _traceApi('HTTP stream error: $e');
          if (!streamController.isClosed) {
            streamController.addError(e);
            streamController.close();
          }
        }
      } catch (e) {
        _traceApi('Unexpected error in HTTP stream: $e');
        if (!streamController.isClosed) {
          streamController.addError(e);
          streamController.close();
        }
      } finally {
        _streamCancelTokens.remove(messageId);
      }
    }();

    return (
      stream: streamController.stream,
      messageId: messageId,
      sessionId: sessionId,
      socketSessionId: socketSessionId,
      isBackgroundFlow: true,
    );
  }

  // === Tasks control (parity with Web client) ===
  Future<void> stopTask(String taskId) async {
    try {
      await _dio.post('/api/tasks/stop/$taskId');
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

  // Cancel an active streaming message by its messageId (client-side abort)
  void cancelStreamingMessage(String messageId) {
    try {
      final token = _streamCancelTokens.remove(messageId);
      if (token != null && !token.isCancelled) {
        token.cancel('User cancelled');
      }
    } catch (_) {}

    try {
      final pid = clearPersistentStreamForMessage(messageId);
      if (pid != null) {
        PersistentStreamingService().unregisterStream(pid);
      }
    } catch (_) {}
  }

  // File upload for RAG
  Future<String> uploadFile(String filePath, String fileName) async {
    _traceApi('Starting file upload: $fileName from $filePath');

    try {
      // Check if file exists
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('File does not exist: $filePath');
      }

      final formData = FormData.fromMap({
        'file': await MultipartFile.fromFile(filePath, filename: fileName),
      });

      _traceApi('Uploading to /api/v1/files/');
      final response = await _dio.post('/api/v1/files/', data: formData);

      DebugLogger.log(
        'upload-status',
        scope: 'api/files',
        data: {'code': response.statusCode},
      );
      DebugLogger.log('upload-ok', scope: 'api/files');

      if (response.data is Map && response.data['id'] != null) {
        final fileId = response.data['id'] as String;
        _traceApi('File uploaded successfully with ID: $fileId');
        return fileId;
      } else {
        throw Exception('Invalid response format: missing file ID');
      }
    } catch (e) {
      DebugLogger.error('upload-failed', scope: 'api/files', error: e);
      rethrow;
    }
  }

  // Search conversations
  Future<List<Conversation>> searchConversations(String query) async {
    final response = await _dio.get(
      '/api/v1/chats/search',
      queryParameters: {'q': query},
    );
    final results = response.data;
    if (results is List) {
      return _parseConversationSummaryList(results, debugLabel: 'parse_search');
    }
    return [];
  }

  // Debug method to test API endpoints
  Future<void> debugApiEndpoints() async {
    _traceApi('=== DEBUG API ENDPOINTS ===');
    _traceApi('Server URL: ${serverConfig.url}');
    _traceApi('Auth token present: ${authToken != null}');

    // Test different possible endpoints
    final endpoints = [
      '/api/v1/chats',
      '/api/chats',
      '/api/v1/conversations',
      '/api/conversations',
    ];

    for (final endpoint in endpoints) {
      try {
        _traceApi('Testing endpoint: $endpoint');
        final response = await _dio.get(endpoint);
        _traceApi('✅ $endpoint - Status: ${response.statusCode}');
        DebugLogger.log(
          'response-type',
          scope: 'api/diagnostics',
          data: {'endpoint': endpoint, 'type': response.data.runtimeType},
        );
        if (response.data is List) {
          DebugLogger.log(
            'array-length',
            scope: 'api/diagnostics',
            data: {
              'endpoint': endpoint,
              'count': (response.data as List).length,
            },
          );
        } else if (response.data is Map) {
          DebugLogger.log(
            'object-keys',
            scope: 'api/diagnostics',
            data: {
              'endpoint': endpoint,
              'keys': (response.data as Map).keys.take(5).toList(),
            },
          );
        }
        DebugLogger.log(
          'sample',
          scope: 'api/diagnostics',
          data: {'endpoint': endpoint, 'preview': response.data.toString()},
        );
      } catch (e) {
        _traceApi('❌ $endpoint - Error: $e');
      }
      _traceApi('---');
    }
    _traceApi('=== END DEBUG ===');
  }

  // Check if server has API documentation
  Future<void> checkApiDocumentation() async {
    _traceApi('=== CHECKING API DOCUMENTATION ===');
    final docEndpoints = ['/docs', '/api/docs', '/swagger', '/api/swagger'];

    for (final endpoint in docEndpoints) {
      try {
        final response = await _dio.get(endpoint);
        if (response.statusCode == 200) {
          _traceApi('✅ API docs available at: ${serverConfig.url}$endpoint');
          if (response.data is String &&
              response.data.toString().contains('swagger')) {
            _traceApi('   This appears to be Swagger documentation');
          }
        }
      } catch (e) {
        _traceApi('❌ No docs at $endpoint');
      }
    }
    _traceApi('=== END API DOCS CHECK ===');
  }

  // dispose() removed – no legacy websocket resources to clean up

  // Helper method to get current weekday name
  // ==================== ADVANCED CHAT FEATURES ====================
  // Chat import/export, bulk operations, and advanced search

  /// Import chat data from external sources
  Future<List<Map<String, dynamic>>> importChats({
    required List<Map<String, dynamic>> chatsData,
    String? folderId,
    bool overwriteExisting = false,
  }) async {
    _traceApi('Importing ${chatsData.length} chats');
    final response = await _dio.post(
      '/api/v1/chats/import',
      data: {
        'chats': chatsData,
        if (folderId != null) 'folder_id': folderId,
        'overwrite_existing': overwriteExisting,
      },
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Export chat data for backup or migration
  Future<List<Map<String, dynamic>>> exportChats({
    List<String>? chatIds,
    String? folderId,
    bool includeMessages = true,
    String? format,
  }) async {
    _traceApi(
      'Exporting chats${chatIds != null ? ' (${chatIds.length} chats)' : ''}',
    );
    final queryParams = <String, dynamic>{};
    if (chatIds != null) queryParams['chat_ids'] = chatIds.join(',');
    if (folderId != null) queryParams['folder_id'] = folderId;
    if (!includeMessages) queryParams['include_messages'] = false;
    if (format != null) queryParams['format'] = format;

    final response = await _dio.get(
      '/api/v1/chats/export',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Archive all chats in bulk
  Future<Map<String, dynamic>> archiveAllChats({
    List<String>? excludeIds,
    String? beforeDate,
  }) async {
    _traceApi('Archiving all chats in bulk');
    final response = await _dio.post(
      '/api/v1/chats/archive/all',
      data: {
        if (excludeIds != null) 'exclude_ids': excludeIds,
        if (beforeDate != null) 'before_date': beforeDate,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// Delete all chats in bulk
  Future<Map<String, dynamic>> deleteAllChats({
    List<String>? excludeIds,
    String? beforeDate,
    bool archived = false,
  }) async {
    _traceApi('Deleting all chats in bulk (archived: $archived)');
    final response = await _dio.post(
      '/api/v1/chats/delete/all',
      data: {
        if (excludeIds != null) 'exclude_ids': excludeIds,
        if (beforeDate != null) 'before_date': beforeDate,
        'archived_only': archived,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// Get pinned chats
  Future<List<Conversation>> getPinnedChats() async {
    _traceApi('Fetching pinned chats');
    final response = await _dio.get('/api/v1/chats/pinned');
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((chatData) {
        final map = Map<String, dynamic>.from(chatData);
        return Conversation.fromJson(parseConversationSummary(map));
      }).toList();
    }
    return [];
  }

  /// Get archived chats
  Future<List<Conversation>> getArchivedChats({int? limit, int? offset}) async {
    _traceApi('Fetching archived chats');
    final queryParams = <String, dynamic>{};
    if (limit != null) queryParams['limit'] = limit;
    if (offset != null) queryParams['offset'] = offset;

    final response = await _dio.get(
      '/api/v1/chats/archived',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data is List) {
      return data.whereType<Map>().map((chatData) {
        final map = Map<String, dynamic>.from(chatData);
        return Conversation.fromJson(parseConversationSummary(map));
      }).toList();
    }
    return [];
  }

  /// Advanced search for chats and messages
  Future<List<Conversation>> searchChats({
    String? query,
    String? userId,
    String? model,
    String? tag,
    String? folderId,
    DateTime? fromDate,
    DateTime? toDate,
    bool? pinned,
    bool? archived,
    int? limit,
    int? offset,
    String? sortBy,
    String? sortOrder,
  }) async {
    _traceApi('Searching chats with query: $query');
    final queryParams = <String, dynamic>{};
    // OpenAPI expects 'text' for this endpoint; keep extras if server tolerates them
    if (query != null) queryParams['text'] = query;
    if (userId != null) queryParams['user_id'] = userId;
    if (model != null) queryParams['model'] = model;
    if (tag != null) queryParams['tag'] = tag;
    if (folderId != null) queryParams['folder_id'] = folderId;
    if (fromDate != null) queryParams['from_date'] = fromDate.toIso8601String();
    if (toDate != null) queryParams['to_date'] = toDate.toIso8601String();
    if (pinned != null) queryParams['pinned'] = pinned;
    if (archived != null) queryParams['archived'] = archived;
    if (limit != null) queryParams['limit'] = limit;
    if (offset != null) queryParams['offset'] = offset;
    if (sortBy != null) queryParams['sort_by'] = sortBy;
    if (sortOrder != null) queryParams['sort_order'] = sortOrder;

    final response = await _dio.get(
      '/api/v1/chats/search',
      queryParameters: queryParams,
    );
    final data = response.data;
    // The endpoint can return a List[ChatTitleIdResponse] or a map.
    // Normalize to a List<Conversation> using our isolate parser.
    if (data is List) {
      return _parseConversationSummaryList(
        data,
        debugLabel: 'parse_search_direct',
      );
    }
    if (data is Map<String, dynamic>) {
      final list = (data['conversations'] ?? data['items'] ?? data['results']);
      if (list is List) {
        return _parseConversationSummaryList(
          list,
          debugLabel: 'parse_search_wrapped',
        );
      }
    }
    return const <Conversation>[];
  }

  /// Search within messages content (capability-safe)
  ///
  /// Many OpenWebUI versions do not expose a dedicated messages search endpoint.
  /// We attempt a GET to `/api/v1/chats/messages/search` and gracefully return
  /// an empty list when the endpoint is missing or method is not allowed
  /// (404/405), avoiding noisy errors.
  Future<List<Map<String, dynamic>>> searchMessages({
    required String query,
    String? chatId,
    String? userId,
    String? role, // 'user' or 'assistant'
    DateTime? fromDate,
    DateTime? toDate,
    int? limit,
    int? offset,
  }) async {
    _traceApi('Searching messages with query: $query');

    // Build query parameters; include both 'text' and 'query' for compatibility
    final qp = <String, dynamic>{
      'text': query,
      'query': query,
      if (chatId != null) 'chat_id': chatId,
      if (userId != null) 'user_id': userId,
      if (role != null) 'role': role,
      if (fromDate != null) 'from_date': fromDate.toIso8601String(),
      if (toDate != null) 'to_date': toDate.toIso8601String(),
      if (limit != null) 'limit': limit,
      if (offset != null) 'offset': offset,
    };

    try {
      final response = await _dio.get(
        '/api/v1/chats/messages/search',
        queryParameters: qp,
        // Accept 404/405 to avoid throwing when endpoint is unsupported
        options: Options(
          validateStatus: (code) =>
              code != null && (code < 400 || code == 404 || code == 405),
        ),
      );

      // If not supported, quietly return empty results
      if (response.statusCode == 404 || response.statusCode == 405) {
        _traceApi(
          'messages search endpoint not supported (status: ${response.statusCode})',
        );
        return [];
      }

      final data = response.data;
      if (data is List) {
        return _normalizeList(data, debugLabel: 'parse_message_search');
      }
      if (data is Map<String, dynamic>) {
        final list = (data['items'] ?? data['results'] ?? data['messages']);
        if (list is List) {
          return _normalizeList(
            list,
            debugLabel: 'parse_message_search_wrapped',
          );
        }
      }
      return const [];
    } on DioException catch (e) {
      // On any transport or other error, degrade gracefully without surfacing
      _traceApi('messages search request failed gracefully: ${e.type}');
      return const [];
    }
  }

  /// Get chat statistics and analytics
  Future<Map<String, dynamic>> getChatStats({
    String? userId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    _traceApi('Fetching chat statistics');
    final queryParams = <String, dynamic>{};
    if (userId != null) queryParams['user_id'] = userId;
    if (fromDate != null) queryParams['from_date'] = fromDate.toIso8601String();
    if (toDate != null) queryParams['to_date'] = toDate.toIso8601String();

    final response = await _dio.get(
      '/api/v1/chats/stats',
      queryParameters: queryParams,
    );
    return response.data as Map<String, dynamic>;
  }

  /// Duplicate/copy a chat
  Future<Conversation> duplicateChat(String chatId, {String? title}) async {
    _traceApi('Duplicating chat: $chatId');
    final response = await _dio.post(
      '/api/v1/chats/$chatId/duplicate',
      data: {if (title != null) 'title': title},
    );
    final json = await _workerManager
        .schedule<Map<String, dynamic>, Map<String, dynamic>>(
          parseFullConversationWorker,
          {'conversation': response.data},
          debugLabel: 'parse_conversation_full',
        );
    return Conversation.fromJson(json);
  }

  /// Get recent chats with activity
  Future<List<Conversation>> getRecentChats({int limit = 10, int? days}) async {
    _traceApi('Fetching recent chats (limit: $limit)');
    final queryParams = <String, dynamic>{'limit': limit};
    if (days != null) queryParams['days'] = days;

    final response = await _dio.get(
      '/api/v1/chats/recent',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(
            (chatData) =>
                Conversation.fromJson(parseConversationSummary(chatData)),
          )
          .toList();
    }
    return [];
  }

  /// Get chat history with pagination and filters
  Future<Map<String, dynamic>> getChatHistory({
    int? limit,
    int? offset,
    String? cursor,
    String? model,
    String? tag,
    bool? pinned,
    bool? archived,
    String? sortBy,
    String? sortOrder,
  }) async {
    _traceApi('Fetching chat history with filters');
    final queryParams = <String, dynamic>{};
    if (limit != null) queryParams['limit'] = limit;
    if (offset != null) queryParams['offset'] = offset;
    if (cursor != null) queryParams['cursor'] = cursor;
    if (model != null) queryParams['model'] = model;
    if (tag != null) queryParams['tag'] = tag;
    if (pinned != null) queryParams['pinned'] = pinned;
    if (archived != null) queryParams['archived'] = archived;
    if (sortBy != null) queryParams['sort_by'] = sortBy;
    if (sortOrder != null) queryParams['sort_order'] = sortOrder;

    final response = await _dio.get(
      '/api/v1/chats/history',
      queryParameters: queryParams,
    );
    return response.data as Map<String, dynamic>;
  }

  /// Batch operations on multiple chats
  Future<Map<String, dynamic>> batchChatOperation({
    required List<String> chatIds,
    required String
    operation, // 'archive', 'delete', 'pin', 'unpin', 'move_to_folder'
    Map<String, dynamic>? params,
  }) async {
    _traceApi(
      'Performing batch operation "$operation" on ${chatIds.length} chats',
    );
    final response = await _dio.post(
      '/api/v1/chats/batch',
      data: {
        'chat_ids': chatIds,
        'operation': operation,
        if (params != null) 'params': params,
      },
    );
    return response.data as Map<String, dynamic>;
  }

  /// Get suggested prompts based on chat history
  Future<List<String>> getChatSuggestions({
    String? context,
    int limit = 5,
  }) async {
    _traceApi('Fetching chat suggestions');
    final queryParams = <String, dynamic>{'limit': limit};
    if (context != null) queryParams['context'] = context;

    final response = await _dio.get(
      '/api/v1/chats/suggestions',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data is List) {
      return data.cast<String>();
    }
    return [];
  }

  /// Get chat templates for quick starts
  Future<List<Map<String, dynamic>>> getChatTemplates({
    String? category,
    String? tag,
  }) async {
    _traceApi('Fetching chat templates');
    final queryParams = <String, dynamic>{};
    if (category != null) queryParams['category'] = category;
    if (tag != null) queryParams['tag'] = tag;

    final response = await _dio.get(
      '/api/v1/chats/templates',
      queryParameters: queryParams,
    );
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  /// Create a chat from template
  Future<Conversation> createChatFromTemplate(
    String templateId, {
    Map<String, dynamic>? variables,
    String? title,
  }) async {
    _traceApi('Creating chat from template: $templateId');
    final response = await _dio.post(
      '/api/v1/chats/templates/$templateId/create',
      data: {
        if (variables != null) 'variables': variables,
        if (title != null) 'title': title,
      },
    );
    final json = await _workerManager
        .schedule<Map<String, dynamic>, Map<String, dynamic>>(
          parseFullConversationWorker,
          {'conversation': response.data},
          debugLabel: 'parse_conversation_full',
        );
    return Conversation.fromJson(json);
  }

  // ==================== END ADVANCED CHAT FEATURES ====================

  // Legacy streaming wrapper methods removed
}

List<Map<String, dynamic>> _normalizeMapListWorker(
  Map<String, dynamic> payload,
) {
  final raw = payload['list'];
  if (raw is! List) {
    return const <Map<String, dynamic>>[];
  }
  final normalized = <Map<String, dynamic>>[];
  for (final entry in raw) {
    if (entry is Map) {
      normalized.add(Map<String, dynamic>.from(entry));
    }
  }
  return normalized;
}
