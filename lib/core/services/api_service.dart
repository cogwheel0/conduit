import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
// import 'package:http_parser/http_parser.dart';
// Removed legacy websocket/socket.io imports
import 'package:uuid/uuid.dart';
import '../models/server_config.dart';
import '../models/user.dart';
import '../models/model.dart';
import '../models/conversation.dart';
import '../models/chat_message.dart';
import '../auth/api_auth_interceptor.dart';
import '../error/api_error_interceptor.dart';
// Tool-call details are parsed in the UI layer to render collapsible blocks
import 'persistent_streaming_service.dart';
import 'connectivity_service.dart';
import '../utils/debug_logger.dart';
import '../utils/openwebui_source_parser.dart';

const bool _traceApiLogs = false;
const bool _traceConversationParsing = false;
const bool _traceFullChatParsing = false;

void _traceApi(String message) {
  if (!_traceApiLogs) {
    return;
  }
  DebugLogger.log(message, scope: 'api/trace');
}

class ApiService {
  final Dio _dio;
  final ServerConfig serverConfig;
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

  ApiService({required this.serverConfig, String? authToken})
    : _dio = Dio(
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
      ) {
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

    // Convert OpenWebUI chat format to our Conversation format
    final conversations = <Conversation>[];
    final pinnedIds = <String>{};
    final archivedIds = <String>{};

    // Process pinned conversations first
    for (final chatData in pinnedChatList) {
      try {
        final conversation = _parseOpenWebUIChat(chatData);
        // Create a new conversation instance with pinned=true
        final pinnedConversation = conversation.copyWith(pinned: true);
        conversations.add(pinnedConversation);
        pinnedIds.add(conversation.id);
      } catch (e) {
        DebugLogger.error(
          'parse-pinned-failed',
          scope: 'api/conversations',
          error: e,
          data: {'conversationId': chatData['id']},
        );
      }
    }

    // Process archived conversations
    for (final chatData in archivedChatList) {
      try {
        final conversation = _parseOpenWebUIChat(chatData);
        // Create a new conversation instance with archived=true
        final archivedConversation = conversation.copyWith(archived: true);
        conversations.add(archivedConversation);
        archivedIds.add(conversation.id);
      } catch (e) {
        DebugLogger.error(
          'parse-archived-failed',
          scope: 'api/conversations',
          error: e,
          data: {'conversationId': chatData['id']},
        );
      }
    }

    // Process regular conversations (excluding pinned and archived ones)
    var loggedSampleChat = false;
    for (final chatData in regularChatList) {
      try {
        // Debug: Check if conversation has folder_id in raw data
        if (chatData.containsKey('folder_id') &&
            chatData['folder_id'] != null) {
          DebugLogger.log(
            'folder-ref',
            scope: 'api/conversations',
            data: {
              'conversationId': chatData['id'],
              'folderId': chatData['folder_id'],
            },
          );
        }

        if (!loggedSampleChat && _traceConversationParsing) {
          loggedSampleChat = true;
          DebugLogger.log(
            'sample-keys',
            scope: 'api/conversations',
            data: {'keys': chatData.keys.take(6).toList()},
          );
          DebugLogger.log(
            'sample-data',
            scope: 'api/conversations',
            data: {'preview': chatData.toString()},
          );
        }

        final conversation = _parseOpenWebUIChat(chatData);
        // Only add if not already added as pinned or archived
        if (!pinnedIds.contains(conversation.id) &&
            !archivedIds.contains(conversation.id)) {
          conversations.add(conversation);
        }
      } catch (e) {
        DebugLogger.error(
          'parse-regular-failed',
          scope: 'api/conversations',
          error: e,
          data: {'conversationId': chatData['id']},
        );
        // Continue with other chats even if one fails
      }
    }

    DebugLogger.log(
      'parse-complete',
      scope: 'api/conversations',
      data: {
        'total': conversations.length,
        'pinned': pinnedIds.length,
        'archived': archivedIds.length,
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

  // Helper method to safely parse timestamps
  DateTime _parseTimestamp(dynamic timestamp) {
    if (timestamp == null) return DateTime.now();

    if (timestamp is int) {
      // OpenWebUI uses Unix timestamps in seconds
      // Check if it's already in milliseconds (13 digits) or seconds (10 digits)
      final timestampMs = timestamp > 1000000000000
          ? timestamp
          : timestamp * 1000;
      return DateTime.fromMillisecondsSinceEpoch(timestampMs);
    }

    if (timestamp is String) {
      final parsed = int.tryParse(timestamp);
      if (parsed != null) {
        final timestampMs = parsed > 1000000000000 ? parsed : parsed * 1000;
        return DateTime.fromMillisecondsSinceEpoch(timestampMs);
      }
    }

    return DateTime.now(); // Fallback to current time
  }

  // Parse OpenWebUI chat format to our Conversation format
  Conversation _parseOpenWebUIChat(Map<String, dynamic> chatData) {
    // OpenWebUI ChatTitleIdResponse format:
    // {
    //   "id": "string",
    //   "title": "string",
    //   "updated_at": integer (timestamp),
    //   "created_at": integer (timestamp),
    //   "pinned": boolean (optional),
    //   "archived": boolean (optional),
    //   "share_id": string (optional),
    //   "folder_id": string (optional)
    // }

    final id = chatData['id'] as String;
    final title = chatData['title'] as String;

    // Safely parse timestamps with validation
    // Try both snake_case and camelCase field names
    final updatedAtRaw = chatData['updated_at'] ?? chatData['updatedAt'];
    final createdAtRaw = chatData['created_at'] ?? chatData['createdAt'];

    final updatedAt = _parseTimestamp(updatedAtRaw);
    final createdAt = _parseTimestamp(createdAtRaw);

    // Parse additional OpenWebUI fields
    // The API response might not include these fields, so we need to handle them safely
    final pinned = chatData['pinned'] as bool? ?? false;
    final archived = chatData['archived'] as bool? ?? false;
    final shareId = chatData['share_id'] as String?;
    final folderId = chatData['folder_id'] as String?;

    // Debug logging for folder assignment
    if (_traceConversationParsing && folderId != null) {
      final idPreview = id.length > 8 ? id.substring(0, 8) : id;
      DebugLogger.log(
        'folder-ref',
        scope: 'api/conversations',
        data: {'conversationId': idPreview, 'folderId': folderId},
      );
    }

    if (_traceConversationParsing) {
      DebugLogger.log(
        'parsed',
        scope: 'api/conversations',
        data: {'id': id, 'pinned': pinned, 'archived': archived},
      );
    }

    String? systemPrompt;
    final chatObject = chatData['chat'] as Map<String, dynamic>?;
    if (chatObject != null) {
      final systemValue = chatObject['system'];
      if (systemValue is String && systemValue.trim().isNotEmpty) {
        systemPrompt = systemValue;
      }
    } else if (chatData['system'] is String) {
      final systemValue = (chatData['system'] as String).trim();
      if (systemValue.isNotEmpty) systemPrompt = systemValue;
    }

    // For the list endpoint, we don't get the full chat messages
    // We'll need to fetch individual chats later if needed
    return Conversation(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      systemPrompt: systemPrompt,
      pinned: pinned,
      archived: archived,
      shareId: shareId,
      folderId: folderId,
      messages: [], // Empty for now, will be loaded when chat is opened
    );
  }

  Future<Conversation> getConversation(String id) async {
    DebugLogger.log('fetch', scope: 'api/chat', data: {'id': id});
    final response = await _dio.get('/api/v1/chats/$id');

    DebugLogger.log('fetch-ok', scope: 'api/chat');

    // Parse OpenWebUI ChatResponse format
    final chatData = response.data as Map<String, dynamic>;
    return _parseFullOpenWebUIChat(chatData);
  }

  // Parse full OpenWebUI chat with messages
  Conversation _parseFullOpenWebUIChat(Map<String, dynamic> chatData) {
    if (_traceFullChatParsing) {
      DebugLogger.log(
        'parse-full',
        scope: 'api/chat',
        data: {'keys': chatData.keys.take(8).toList()},
      );
    }

    final id = chatData['id'] as String;
    final title = chatData['title'] as String;

    if (_traceFullChatParsing) {
      DebugLogger.log(
        'chat-meta',
        scope: 'api/chat',
        data: {'id': id, 'title': title},
      );
    }

    // Safely parse timestamps with validation
    final updatedAt = _parseTimestamp(chatData['updated_at']);
    final createdAt = _parseTimestamp(chatData['created_at']);

    // Parse additional OpenWebUI fields
    final pinned = chatData['pinned'] as bool? ?? false;
    final archived = chatData['archived'] as bool? ?? false;
    final shareId = chatData['share_id'] as String?;
    final folderId = chatData['folder_id'] as String?;

    // Parse messages from the 'chat' object or top-level messages
    final chatObject = chatData['chat'] as Map<String, dynamic>?;
    String? systemPrompt;
    if (chatObject != null) {
      final systemValue = chatObject['system'];
      if (systemValue is String && systemValue.trim().isNotEmpty) {
        systemPrompt = systemValue;
      }
    } else if (chatData['system'] is String) {
      final systemValue = (chatData['system'] as String).trim();
      if (systemValue.isNotEmpty) systemPrompt = systemValue;
    }
    final messages = <ChatMessage>[];

    // Extract model from chat.models array
    String? model;
    if (chatObject != null && chatObject['models'] != null) {
      final models = chatObject['models'] as List?;
      if (models != null && models.isNotEmpty) {
        model = models.first as String;
        if (_traceFullChatParsing) {
          DebugLogger.log(
            'model',
            scope: 'api/chat',
            data: {'id': id, 'model': model},
          );
        }
      }
    }

    // Try multiple locations for messages - prefer history-based ordering like Open‑WebUI
    List? messagesList;
    Map<String, dynamic>? historyMessagesMap;

    if (chatObject != null) {
      // Prefer history.messages with currentId to reconstruct the selected branch
      final history = chatObject['history'] as Map<String, dynamic>?;
      if (history != null && history['messages'] is Map<String, dynamic>) {
        historyMessagesMap = history['messages'] as Map<String, dynamic>;

        // Reconstruct ordered list using parent chain up to currentId
        final currentId = history['currentId']?.toString();
        if (currentId != null && currentId.isNotEmpty) {
          messagesList = _buildMessagesListFromHistory(history);
          if (_traceFullChatParsing) {
            DebugLogger.log(
              'history-chain',
              scope: 'api/chat',
              data: {
                'id': id,
                'count': messagesList.length,
                'currentId': currentId,
              },
            );
          }
        }
      }

      // Fallback to chat.messages (list format) if history is missing or empty
      if (((messagesList?.isEmpty ?? true)) && chatObject['messages'] != null) {
        messagesList = chatObject['messages'] as List;
        if (_traceFullChatParsing) {
          DebugLogger.log(
            'messages-fallback',
            scope: 'api/chat',
            data: {'id': id, 'count': messagesList.length},
          );
        }
      }
    } else if (chatData['messages'] != null) {
      messagesList = chatData['messages'] as List;
      if (_traceFullChatParsing) {
        DebugLogger.log(
          'messages-top-level',
          scope: 'api/chat',
          data: {'id': id, 'count': messagesList.length},
        );
      }
    }

    // Parse messages from list format only (avoiding duplication)
    if (messagesList != null) {
      for (int idx = 0; idx < messagesList.length; idx++) {
        final msgData = messagesList[idx] as Map<String, dynamic>;
        try {
          if (_traceFullChatParsing) {
            DebugLogger.log(
              'message-parse',
              scope: 'api/chat',
              data: {
                'chatId': id,
                'messageId': msgData['id'],
                'role': msgData['role'],
                'contentLen': msgData['content']?.toString().length ?? 0,
              },
            );
          }

          // If this assistant message includes tool_calls, merge following tool results
          final historyMsg = historyMessagesMap != null
              ? (historyMessagesMap[msgData['id']] as Map<String, dynamic>?)
              : null;

          final toolCalls = (msgData['tool_calls'] is List)
              ? (msgData['tool_calls'] as List)
              : (historyMsg != null && historyMsg['tool_calls'] is List)
              ? (historyMsg['tool_calls'] as List)
              : null;

          if ((msgData['role']?.toString() == 'assistant') &&
              toolCalls is List) {
            // Collect subsequent tool results associated with this assistant turn
            final List<Map<String, dynamic>> results = [];
            int j = idx + 1;
            while (j < messagesList.length) {
              final next = messagesList[j] as Map<String, dynamic>;
              if ((next['role']?.toString() ?? '') != 'tool') break;
              final toolCallId = next['tool_call_id']?.toString();
              final resContent = next['content'];
              final resFiles = next['files'];
              results.add({
                'tool_call_id': toolCallId,
                'content': resContent,
                if (resFiles != null) 'files': resFiles,
              });
              j++;
            }

            // Synthesize content from tool_calls and results
            final synthesized = _synthesizeToolDetailsFromToolCallsWithResults(
              toolCalls,
              results,
            );

            final mergedAssistant = Map<String, dynamic>.from(msgData);
            mergedAssistant['content'] = synthesized;

            final message = _parseOpenWebUIMessage(
              mergedAssistant,
              historyMsg: historyMsg,
            );
            messages.add(message);

            // Skip the tool messages we just merged
            idx = j - 1;
            if (_traceFullChatParsing) {
              DebugLogger.log(
                'message-tool-call',
                scope: 'api/chat',
                data: {'chatId': id, 'messageId': message.id},
              );
            }
            continue;
          }

          // Default path: parse message as-is
          final message = _parseOpenWebUIMessage(
            msgData,
            historyMsg: historyMsg,
          );
          messages.add(message);
          if (_traceFullChatParsing) {
            DebugLogger.log(
              'message',
              scope: 'api/chat',
              data: {
                'chatId': id,
                'messageId': message.id,
                'role': message.role,
              },
            );
          }
        } catch (e) {
          DebugLogger.error(
            'message-parse-failed',
            scope: 'api/chat',
            error: e,
            data: {'chatId': id, 'messageId': msgData['id']},
          );
        }
      }
    }

    if (_traceFullChatParsing) {
      DebugLogger.log(
        'message-count',
        scope: 'api/chat',
        data: {'chatId': id, 'count': messages.length},
      );
    }

    return Conversation(
      id: id,
      title: title,
      createdAt: createdAt,
      updatedAt: updatedAt,
      model: model,
      systemPrompt: systemPrompt,
      pinned: pinned,
      archived: archived,
      shareId: shareId,
      folderId: folderId,
      messages: messages,
    );
  }

  // Parse OpenWebUI message format to our ChatMessage format
  ChatMessage _parseOpenWebUIMessage(
    Map<String, dynamic> msgData, {
    Map<String, dynamic>? historyMsg,
  }) {
    // OpenWebUI message format may vary, but typically:
    // { "role": "user|assistant", "content": "text", ... }

    // Create a single UUID instance to reuse
    const uuid = Uuid();

    // Prefer richer content from history entry if present
    dynamic content = msgData['content'];
    if ((content == null || (content is String && content.isEmpty)) &&
        historyMsg != null &&
        historyMsg['content'] != null) {
      content = historyMsg['content'];
    }
    String contentString;
    if (content is List) {
      // Concatenate all text fragments in order (Open‑WebUI may split long text)
      final buffer = StringBuffer();
      for (final item in content) {
        if (item is Map && item['type'] == 'text') {
          final t = item['text']?.toString();
          if (t != null && t.isNotEmpty) buffer.write(t);
        }
      }
      contentString = buffer.toString();
      if (contentString.trim().isEmpty) {
        // Fallback: look for tool-related entries in the array and synthesize details blocks
        final synthesized = _synthesizeToolDetailsFromContentArray(content);
        if (synthesized.isNotEmpty) {
          contentString = synthesized;
        }
      }
    } else {
      contentString = (content as String?) ?? '';
    }

    // Prefer longer content from history if available (guards against truncated previews)
    if (historyMsg != null) {
      final histContent = historyMsg['content'];
      if (histContent is String && histContent.length > contentString.length) {
        contentString = histContent;
      } else if (histContent is List) {
        final buf = StringBuffer();
        for (final item in histContent) {
          if (item is Map && item['type'] == 'text') {
            final t = item['text']?.toString();
            if (t != null && t.isNotEmpty) buf.write(t);
          }
        }
        final combined = buf.toString();
        if (combined.length > contentString.length) {
          contentString = combined;
        }
      }
    }

    // Final fallback: some servers store tool calls under tool_calls instead of content
    final toolCallsList = (msgData['tool_calls'] is List)
        ? (msgData['tool_calls'] as List)
        : (historyMsg != null && historyMsg['tool_calls'] is List)
        ? (historyMsg['tool_calls'] as List)
        : null;
    if (contentString.trim().isEmpty && toolCallsList is List) {
      final synthesized = _synthesizeToolDetailsFromToolCalls(toolCallsList);
      if (synthesized.isNotEmpty) {
        contentString = synthesized;
      }
    }

    // Determine role based on available fields
    String role;
    if (msgData['role'] != null) {
      role = msgData['role'] as String;
    } else if (msgData['model'] != null) {
      // Messages with model field are typically assistant messages
      role = 'assistant';
    } else {
      // Default to user if no role or model
      role = 'user';
    }

    // Parse attachments and generated images from 'files' field
    List<String>? attachmentIds;
    List<Map<String, dynamic>>? files;

    final effectiveFiles = msgData['files'] ?? historyMsg?['files'];
    if (effectiveFiles != null) {
      final filesList = effectiveFiles as List;

      // Handle different file formats from OpenWebUI
      final userAttachments = <String>[];
      final allFiles = <Map<String, dynamic>>[];

      for (final file in filesList) {
        if (file is Map) {
          if (file['file_id'] != null) {
            // User uploaded file with file_id (legacy format)
            userAttachments.add(file['file_id'] as String);
          } else if (file['type'] != null && file['url'] != null) {
            // File with type and url (OpenWebUI format)
            final fileMap = <String, dynamic>{
              'type': file['type'],
              'url': file['url'],
            };

            // Add optional fields if present
            if (file['name'] != null) fileMap['name'] = file['name'];
            if (file['size'] != null) fileMap['size'] = file['size'];

            allFiles.add(fileMap);

            // If this is a user-uploaded file (URL contains file ID), also extract the ID
            final url = file['url'] as String;
            if (url.contains('/api/v1/files/') && url.contains('/content')) {
              final fileIdMatch = RegExp(
                r'/api/v1/files/([^/]+)/content',
              ).firstMatch(url);
              if (fileIdMatch != null) {
                userAttachments.add(fileIdMatch.group(1)!);
              }
            }
          }
        }
      }

      attachmentIds = userAttachments.isNotEmpty ? userAttachments : null;
      files = allFiles.isNotEmpty ? allFiles : null;
    }

    final dynamic statusRaw =
        historyMsg != null && historyMsg.containsKey('statusHistory')
        ? historyMsg['statusHistory']
        : msgData['statusHistory'];
    final statusHistory = _parseStatusHistoryField(statusRaw);

    final dynamic followUpsRaw =
        historyMsg != null && historyMsg.containsKey('followUps')
        ? historyMsg['followUps']
        : msgData['followUps'] ?? msgData['follow_ups'];
    final followUps = _parseFollowUpsField(followUpsRaw);

    final dynamic codeExecRaw = historyMsg != null
        ? (historyMsg['code_executions'] ?? historyMsg['codeExecutions'])
        : (msgData['code_executions'] ?? msgData['codeExecutions']);
    final codeExecutions = _parseCodeExecutionsField(codeExecRaw);

    final dynamic sourcesRaw =
        historyMsg != null && historyMsg.containsKey('sources')
        ? historyMsg['sources']
        : msgData['sources'];
    final sources = _parseSourcesField(sourcesRaw);

    return ChatMessage(
      id: msgData['id']?.toString() ?? uuid.v4(),
      role: role,
      content: contentString,
      timestamp: _parseTimestamp(msgData['timestamp']),
      model: msgData['model'] as String?,
      attachmentIds: attachmentIds,
      files: files,
      statusHistory: statusHistory,
      followUps: followUps,
      codeExecutions: codeExecutions,
      sources: sources,
    );
  }

  // Build ordered messages list from Open‑WebUI history using parent chain to currentId
  List<Map<String, dynamic>> _buildMessagesListFromHistory(
    Map<String, dynamic> history,
  ) {
    final messagesMap = history['messages'] as Map<String, dynamic>?;
    final currentId = history['currentId']?.toString();

    if (messagesMap == null || currentId == null) return [];

    List<Map<String, dynamic>> buildChain(String? id) {
      if (id == null) return [];
      final raw = messagesMap[id];
      if (raw == null) return [];
      final msg = Map<String, dynamic>.from(raw as Map<String, dynamic>);
      msg['id'] = id; // ensure id present
      final parentId = msg['parentId']?.toString();
      if (parentId != null && parentId.isNotEmpty) {
        return [...buildChain(parentId), msg];
      }
      return [msg];
    }

    return buildChain(currentId);
  }

  // ===== Helpers to synthesize tool-call details blocks for UI parsing =====
  String _escapeHtmlAttr(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  String _jsonStringify(dynamic v) {
    try {
      return jsonEncode(v);
    } catch (_) {
      return v?.toString() ?? '';
    }
  }

  String _synthesizeToolDetailsFromToolCalls(List toolCalls) {
    final buf = StringBuffer();
    for (final c in toolCalls) {
      if (c is! Map) continue;
      final func = c['function'] as Map?;
      final name =
          (func != null ? func['name'] : c['name'])?.toString() ?? 'tool';
      final id =
          (c['id']?.toString() ??
          'call_${DateTime.now().millisecondsSinceEpoch}');
      final done = (c['done']?.toString() ?? 'true');
      final argsRaw = func != null ? func['arguments'] : c['arguments'];
      final resRaw =
          c['result'] ?? c['output'] ?? (func != null ? func['result'] : null);
      final argsStr = _jsonStringify(argsRaw);
      final resStr = resRaw != null ? _jsonStringify(resRaw) : null;
      final attrs = StringBuffer()
        ..write('type="tool_calls"')
        ..write(' done="${_escapeHtmlAttr(done)}"')
        ..write(' id="${_escapeHtmlAttr(id)}"')
        ..write(' name="${_escapeHtmlAttr(name)}"')
        ..write(' arguments="${_escapeHtmlAttr(argsStr)}"');
      if (resStr != null && resStr.isNotEmpty) {
        attrs.write(' result="${_escapeHtmlAttr(resStr)}"');
      }
      buf.writeln(
        '<details ${attrs.toString()}><summary>Tool Executed</summary>',
      );
      buf.writeln('</details>');
    }
    return buf.toString().trim();
  }

  String _synthesizeToolDetailsFromToolCallsWithResults(
    List toolCalls,
    List<Map<String, dynamic>> results,
  ) {
    final buf = StringBuffer();
    Map<String, Map<String, dynamic>> resultsMap = {};
    for (final r in results) {
      final id = r['tool_call_id']?.toString();
      if (id != null) resultsMap[id] = r;
    }

    for (final c in toolCalls) {
      if (c is! Map) continue;
      final func = c['function'] as Map?;
      final name =
          (func != null ? func['name'] : c['name'])?.toString() ?? 'tool';
      final id =
          (c['id']?.toString() ??
          'call_${DateTime.now().millisecondsSinceEpoch}');
      final argsRaw = func != null ? func['arguments'] : c['arguments'];
      final argsStr = _jsonStringify(argsRaw);
      final resultEntry = resultsMap[id];
      final resRaw = resultEntry != null ? resultEntry['content'] : null;
      final filesRaw = resultEntry != null ? resultEntry['files'] : null;
      final resStr = resRaw != null ? _jsonStringify(resRaw) : null;
      final filesStr = filesRaw != null ? _jsonStringify(filesRaw) : null;

      final attrs = StringBuffer()
        ..write('type="tool_calls"')
        ..write(
          ' done="${_escapeHtmlAttr(resultEntry != null ? 'true' : 'false')}"',
        )
        ..write(' id="${_escapeHtmlAttr(id)}"')
        ..write(' name="${_escapeHtmlAttr(name)}"')
        ..write(' arguments="${_escapeHtmlAttr(argsStr)}"');
      if (resStr != null && resStr.isNotEmpty) {
        attrs.write(' result="${_escapeHtmlAttr(resStr)}"');
      }
      if (filesStr != null && filesStr.isNotEmpty) {
        attrs.write(' files="${_escapeHtmlAttr(filesStr)}"');
      }

      buf.writeln(
        '<details ${attrs.toString()}><summary>${resultEntry != null ? 'Tool Executed' : 'Executing...'}</summary>',
      );
      buf.writeln('</details>');
    }
    return buf.toString().trim();
  }

  String _synthesizeToolDetailsFromContentArray(List content) {
    final buf = StringBuffer();
    for (final item in content) {
      if (item is! Map) continue;
      final type = item['type']?.toString();
      if (type == null) continue;
      // OpenWebUI content-blocks shape: { type: 'tool_calls', content: [...], results: [...] }
      if (type == 'tool_calls') {
        final calls = (item['content'] is List)
            ? (item['content'] as List)
            : <dynamic>[];
        final results = <Map<String, dynamic>>[];
        if (item['results'] is List) {
          for (final r in (item['results'] as List)) {
            if (r is Map<String, dynamic>) results.add(r);
          }
        }
        final synthesized = _synthesizeToolDetailsFromToolCallsWithResults(
          calls,
          results,
        );
        if (synthesized.isNotEmpty) buf.writeln(synthesized);
        continue;
      }

      // Heuristics: handle other variants (single tool/function call entries)
      if (type == 'tool_call' || type == 'function_call') {
        final name = (item['name'] ?? item['tool'] ?? 'tool').toString();
        final id =
            (item['id']?.toString() ??
            'call_${DateTime.now().millisecondsSinceEpoch}');
        final argsStr = _jsonStringify(item['arguments'] ?? item['args']);
        final resStr = item['result'] ?? item['output'] ?? item['response'];
        final attrs = StringBuffer()
          ..write('type="tool_calls"')
          ..write(
            ' done="${_escapeHtmlAttr(resStr != null ? 'true' : 'false')}"',
          )
          ..write(' id="${_escapeHtmlAttr(id)}"')
          ..write(' name="${_escapeHtmlAttr(name)}"')
          ..write(' arguments="${_escapeHtmlAttr(argsStr)}"');
        if (resStr != null) {
          final r = _jsonStringify(resStr);
          if (r.isNotEmpty) attrs.write(' result="${_escapeHtmlAttr(r)}"');
        }
        buf.writeln(
          '<details ${attrs.toString()}><summary>${resStr != null ? 'Tool Executed' : 'Executing...'}</summary>',
        );
        buf.writeln('</details>');
      }
    }
    return buf.toString().trim();
  }

  List<ChatStatusUpdate> _parseStatusHistoryField(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((entry) {
            try {
              // Convert Map to Map<String, dynamic> safely
              final Map<String, dynamic> statusMap = {};
              entry.forEach((key, value) {
                statusMap[key.toString()] = value;
              });
              final statusUpdate = ChatStatusUpdate.fromJson(statusMap);

              // Debug log to help diagnose template issues
              if (statusUpdate.description?.contains('{{count}}') == true) {
                DebugLogger.log(
                  'template-placeholder-found',
                  scope: 'api/chat',
                  data: {
                    'description': statusUpdate.description,
                    'count': statusUpdate.count,
                    'urls': statusUpdate.urls.length,
                    'items': statusUpdate.items.length,
                    'action': statusUpdate.action,
                  },
                );
              }

              return statusUpdate;
            } catch (e) {
              // Log the error and skip this entry
              DebugLogger.log(
                'status-parse-error',
                scope: 'api/chat',
                data: {'error': e.toString(), 'entry': entry.toString()},
              );
              return null;
            }
          })
          .where((item) => item != null)
          .cast<ChatStatusUpdate>()
          .toList(growable: false);
    }
    return const <ChatStatusUpdate>[];
  }

  List<String> _parseFollowUpsField(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<dynamic>()
          .map((value) => value?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return [raw.trim()];
    }
    return const <String>[];
  }

  List<ChatCodeExecution> _parseCodeExecutionsField(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((entry) {
            try {
              // Convert Map to Map<String, dynamic> safely
              final Map<String, dynamic> execMap = {};
              entry.forEach((key, value) {
                execMap[key.toString()] = value;
              });
              return ChatCodeExecution.fromJson(execMap);
            } catch (e) {
              // Log the error and skip this entry
              DebugLogger.log(
                'code-exec-parse-error',
                scope: 'api/chat',
                data: {'error': e.toString(), 'entry': entry.toString()},
              );
              return null;
            }
          })
          .where((item) => item != null)
          .cast<ChatCodeExecution>()
          .toList(growable: false);
    }
    return const <ChatCodeExecution>[];
  }

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

  List<ChatSourceReference> _parseSourcesField(dynamic raw) {
    try {
      return parseOpenWebUISourceList(raw);
    } catch (_) {
      return const <ChatSourceReference>[];
    }
  }

  // Create new conversation using OpenWebUI API
  Future<Conversation> createConversation({
    required String title,
    required List<ChatMessage> messages,
    String? model,
    String? systemPrompt,
  }) async {
    _traceApi('Creating new conversation on OpenWebUI server');
    _traceApi('Title: $title, Messages: ${messages.length}');

    // Build messages with parent-child relationships
    final Map<String, dynamic> messagesMap = {};
    final List<Map<String, dynamic>> messagesArray = [];
    String? currentId;
    String? previousId;

    for (final msg in messages) {
      final messageId = msg.id;

      // Build message for history.messages map
      messagesMap[messageId] = {
        'id': messageId,
        'parentId': previousId,
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
      if (previousId != null && messagesMap.containsKey(previousId)) {
        (messagesMap[previousId]['childrenIds'] as List).add(messageId);
      }

      // Build message for messages array
      messagesArray.add({
        'id': messageId,
        'parentId': previousId,
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
      'folder_id': null,
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

    // Parse the response
    final responseData = response.data as Map<String, dynamic>;
    return _parseFullOpenWebUIChat(responseData);
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

    for (final msg in messages) {
      final messageId = msg.id;

      // Use the properly formatted files array for WebUI display
      // The msg.files array already contains all attachments in the correct format
      final sanitizedFiles = _sanitizeFilesForWebUI(msg.files);

      messagesMap[messageId] = {
        'id': messageId,
        'parentId': previousId,
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
      if (previousId != null && messagesMap.containsKey(previousId)) {
        (messagesMap[previousId]['childrenIds'] as List).add(messageId);
      }

      // Use the same properly formatted files array for messages array
      final sanitizedArrayFiles = _sanitizeFilesForWebUI(msg.files);

      messagesArray.add({
        'id': messageId,
        'parentId': previousId,
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
    return _parseFullOpenWebUIChat(response.data as Map<String, dynamic>);
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
      return data.map((chatData) => _parseOpenWebUIChat(chatData)).toList();
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
      return data.map((chatData) => _parseOpenWebUIChat(chatData)).toList();
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

  Future<List<Map<String, dynamic>>> getUserFiles() async {
    _traceApi('Fetching user files');
    final response = await _dio.get('/api/v1/files/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  // Enhanced File Operations
  Future<List<Map<String, dynamic>>> searchFiles({
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
      return data.cast<Map<String, dynamic>>();
    }
    return [];
  }

  Future<List<Map<String, dynamic>>> getAllFiles() async {
    _traceApi('Fetching all files (admin)');
    final response = await _dio.get('/api/v1/files/all');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
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
  Future<List<Map<String, dynamic>>> getKnowledgeBases() async {
    _traceApi('Fetching knowledge bases');
    final response = await _dio.get('/api/v1/knowledge/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
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

  Future<List<Map<String, dynamic>>> getKnowledgeBaseItems(
    String knowledgeBaseId,
  ) async {
    _traceApi('Fetching knowledge base items: $knowledgeBaseId');
    final response = await _dio.get('/api/v1/knowledge/$knowledgeBaseId/items');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
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
  Future<List<String>> getAvailableVoices() async {
    _traceApi('Fetching available voices');
    final response = await _dio.get('/api/v1/audio/voices');
    final data = response.data;
    if (data is List) {
      return data.cast<String>();
    }
    return [];
  }

  Future<List<int>> generateSpeech({
    required String text,
    String? voice,
  }) async {
    final textPreview = text.length > 50 ? text.substring(0, 50) : text;
    _traceApi('Generating speech for text: $textPreview...');
    final response = await _dio.post(
      '/api/v1/audio/speech',
      data: {'text': text, if (voice != null) 'voice': voice},
    );

    // Return audio data as bytes
    if (response.data is List) {
      return (response.data as List).cast<int>();
    }
    return [];
  }

  // Server audio transcription removed; rely on on-device STT in UI layer

  // Image Generation
  Future<List<Map<String, dynamic>>> getImageModels() async {
    _traceApi('Fetching image generation models');
    final response = await _dio.get('/api/v1/images/models');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
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
  Future<List<Map<String, dynamic>>> getPrompts() async {
    _traceApi('Fetching prompts');
    final response = await _dio.get('/api/v1/prompts/');
    final data = response.data;
    if (data is List) {
      return data.cast<Map<String, dynamic>>();
    }
    return [];
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
      return data.map((chatData) => _parseOpenWebUIChat(chatData)).toList();
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

  // Send message using the background flow (socket push + polling fallback).
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

      // Hint server to use native function calling when tools are selected
      // This enables provider-native tool execution paths and consistent UI events
      try {
        final params =
            (data['params'] as Map<String, dynamic>?) ?? <String, dynamic>{};
        params['function_calling'] = 'native';
        data['params'] = params;
        _traceApi('Set params.function_calling = native');
      } catch (_) {
        // Non-fatal; continue without forcing native mode
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

    _traceApi('Preparing chat send request (backgroundFlow: true)');
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
      'Forcing background flow (hasBackgroundTasks: '
      '$hasBackgroundTasksPayload, tools: ${toolIds?.isNotEmpty == true}, '
      'webSearch: $enableWebSearch, imageGen: $enableImageGeneration, '
      'sessionOverride: ${sessionIdOverride != null && sessionIdOverride.isNotEmpty})',
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

    _traceApi('Initiating background tools flow (task-based)');
    _traceApi('Posting to /api/chat/completions');

    // Fire in background; poll chat for updates and stream deltas to UI
    () async {
      try {
        final resp = await _dio.post('/api/chat/completions', data: data);
        final respData = resp.data;
        final taskId = (respData is Map)
            ? (respData['task_id']?.toString())
            : null;
        _traceApi('Background task created: $taskId');

        // If no session/socket provided, fall back to polling for updates.
        final pollChatId = (conversationId != null && conversationId.isNotEmpty)
            ? conversationId
            : null;
        final requiresPolling =
            sessionIdOverride == null || sessionIdOverride.isEmpty;

        if (requiresPolling && pollChatId != null) {
          final chatId = pollChatId;
          await _pollChatForMessageUpdates(
            chatId: chatId,
            messageId: messageId,
            streamController: streamController,
          );
        } else {
          // Close the controller so listeners don't hang waiting for chunks
          if (!streamController.isClosed) {
            streamController.close();
          }
        }
      } catch (e) {
        _traceApi('Background tools flow failed: $e');
        if (!streamController.isClosed) streamController.close();
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

  // Poll the server chat until the assistant message is populated with tool results,
  // then stream deltas to the UI and close.
  Future<void> _pollChatForMessageUpdates({
    required String chatId,
    required String messageId,
    required StreamController<String> streamController,
  }) async {
    String last = '';
    int stableCount = 0;
    final started = DateTime.now();

    bool containsDone(String s) =>
        s.contains('<details type="tool_calls"') && s.contains('done="true"');

    // Allow much longer time for large completions, matching OpenWebUI's generous timeouts
    while (DateTime.now().difference(started).inSeconds < 600) {
      // Increased from 180 to 600 seconds (10 minutes)
      try {
        // Small delay between polls
        await Future.delayed(const Duration(milliseconds: 900));

        final resp = await _dio.get('/api/v1/chats/$chatId');
        final data = resp.data as Map<String, dynamic>;

        // Locate assistant content from multiple shapes
        String content = '';

        Map<String, dynamic>? chatObj = (data['chat'] is Map<String, dynamic>)
            ? data['chat'] as Map<String, dynamic>
            : null;

        // 1) Preferred: chat.messages (list) – try exact id first
        if (chatObj != null && chatObj['messages'] is List) {
          final List messagesList = chatObj['messages'] as List;
          final target = messagesList.firstWhere(
            (m) => (m is Map && (m['id']?.toString() == messageId)),
            orElse: () => null,
          );
          if (target != null) {
            final rawContent = (target as Map)['content'];
            if (rawContent is List) {
              final textItem = rawContent.firstWhere(
                (i) => i is Map && i['type'] == 'text',
                orElse: () => null,
              );
              if (textItem != null) {
                content = textItem['text']?.toString() ?? '';
              }
            } else if (rawContent is String) {
              content = rawContent;
            }
          }
        }

        // 2) Fallback: chat.history.messages (map) – try exact id
        if (content.isEmpty && chatObj != null) {
          final history = chatObj['history'];
          if (history is Map && history['messages'] is Map) {
            final Map<String, dynamic> messagesMap =
                (history['messages'] as Map).cast<String, dynamic>();
            final msg = messagesMap[messageId];
            if (msg is Map) {
              final rawContent = msg['content'];
              if (rawContent is String) {
                content = rawContent;
              } else if (rawContent is List) {
                final textItem = rawContent.firstWhere(
                  (i) => i is Map && i['type'] == 'text',
                  orElse: () => null,
                );
                if (textItem != null) {
                  content = textItem['text']?.toString() ?? '';
                }
              }
            }
          }
        }

        // 3) Last resort: top-level messages (list) – try exact id
        if (content.isEmpty && data['messages'] is List) {
          final List topMessages = data['messages'] as List;
          final target = topMessages.firstWhere(
            (m) => (m is Map && (m['id']?.toString() == messageId)),
            orElse: () => null,
          );
          if (target != null) {
            final rawContent = (target as Map)['content'];
            if (rawContent is String) {
              content = rawContent;
            } else if (rawContent is List) {
              final textItem = rawContent.firstWhere(
                (i) => i is Map && i['type'] == 'text',
                orElse: () => null,
              );
              if (textItem != null) {
                content = textItem['text']?.toString() ?? '';
              }
            }
          }
        }

        // 4) If nothing found by id, fall back to the latest assistant message
        if (content.isEmpty) {
          // Prefer chat.messages list
          if (chatObj != null && chatObj['messages'] is List) {
            final List messagesList = chatObj['messages'] as List;
            // Find last assistant
            for (int i = messagesList.length - 1; i >= 0; i--) {
              final m = messagesList[i];
              if (m is Map && (m['role']?.toString() == 'assistant')) {
                final rawContent = m['content'];
                if (rawContent is String) {
                  content = rawContent;
                } else if (rawContent is List) {
                  final textItem = rawContent.firstWhere(
                    (i) => i is Map && i['type'] == 'text',
                    orElse: () => null,
                  );
                  if (textItem != null) {
                    content = textItem['text']?.toString() ?? '';
                  }
                }
                if (content.isNotEmpty) break;
              }
            }
          }

          // Try history map if still empty
          if (content.isEmpty && chatObj != null) {
            final history = chatObj['history'];
            if (history is Map && history['messages'] is Map) {
              final Map<dynamic, dynamic> msgMapDyn =
                  history['messages'] as Map;
              // Iterate by values; no guaranteed ordering, but often sufficient
              for (final entry in msgMapDyn.values) {
                if (entry is Map &&
                    (entry['role']?.toString() == 'assistant')) {
                  final rawContent = entry['content'];
                  if (rawContent is String) {
                    content = rawContent;
                  } else if (rawContent is List) {
                    final textItem = rawContent.firstWhere(
                      (i) => i is Map && i['type'] == 'text',
                      orElse: () => null,
                    );
                    if (textItem != null) {
                      content = textItem['text']?.toString() ?? '';
                    }
                  }
                  if (content.isNotEmpty) break;
                }
              }
            }
          }
        }

        if (content.isEmpty) {
          continue;
        }

        // Stream only the delta when content grows monotonically
        if (content.startsWith(last)) {
          final delta = content.substring(last.length);
          if (delta.isNotEmpty && !streamController.isClosed) {
            streamController.add(delta);
          }
        } else {
          // Fallback: replace entire content by emitting a separator + full content
          if (!streamController.isClosed) {
            streamController.add('\n');
            streamController.add(content);
          }
        }
        // Stop when we detect done=true on tool_calls or when content stabilizes
        if (containsDone(content)) {
          break;
        }

        // If content hasn't changed for several polls, assume completion,
        // but be more conservative to avoid cutting off long responses.
        // OpenWebUI relies more on explicit done signals than stability checks.
        final prev = last;
        if (content == prev && content.isNotEmpty) {
          stableCount++;
        } else if (content != prev) {
          stableCount = 0;
        }
        // Increased threshold from 3 to 8 polls to be more conservative
        // This gives ~7-8 seconds of stability before assuming completion
        if (content.isNotEmpty && stableCount >= 8) {
          DebugLogger.log(
            'Content stable for $stableCount polls, assuming completion',
            scope: 'api/polling',
          );
          break;
        }

        last = content;
      } catch (e) {
        // Ignore transient errors and continue polling
      }
    }

    // Final backfill: one last attempt to fetch the latest content
    // in case the server wrote the final message after our last poll.
    try {
      if (!streamController.isClosed) {
        final resp = await _dio.get('/api/v1/chats/$chatId');
        final data = resp.data as Map<String, dynamic>;
        String content = '';
        Map<String, dynamic>? chatObj = (data['chat'] is Map<String, dynamic>)
            ? data['chat'] as Map<String, dynamic>
            : null;
        if (chatObj != null && chatObj['messages'] is List) {
          final List messagesList = chatObj['messages'] as List;
          final target = messagesList.firstWhere(
            (m) => (m is Map && (m['id']?.toString() == messageId)),
            orElse: () => null,
          );
          if (target != null) {
            final rawContent = (target as Map)['content'];
            if (rawContent is String) {
              content = rawContent;
            } else if (rawContent is List) {
              final textItem = rawContent.firstWhere(
                (i) => i is Map && i['type'] == 'text',
                orElse: () => null,
              );
              if (textItem != null) {
                content = (textItem as Map)['text']?.toString() ?? '';
              }
            }
          }
        }
        if (content.isEmpty && chatObj != null) {
          final history = chatObj['history'];
          if (history is Map && history['messages'] is Map) {
            final Map<String, dynamic> messagesMap =
                (history['messages'] as Map).cast<String, dynamic>();
            final msg = messagesMap[messageId];
            if (msg is Map) {
              final rawContent = msg['content'];
              if (rawContent is String) {
                content = rawContent;
              } else if (rawContent is List) {
                final textItem = rawContent.firstWhere(
                  (i) => i is Map && i['type'] == 'text',
                  orElse: () => null,
                );
                if (textItem != null) {
                  content = (textItem as Map)['text']?.toString() ?? '';
                }
              }
            }
          }
        }
        if (content.isNotEmpty && content != last) {
          streamController.add('\n');
          streamController.add(content);
        }
      }
    } catch (_) {}

    if (!streamController.isClosed) {
      streamController.close();
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
      final pid = _messagePersistentStreamIds.remove(messageId);
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
    final results = response.data as List;
    return results.map((c) => Conversation.fromJson(c)).toList();
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
      return data.map((chatData) => _parseOpenWebUIChat(chatData)).toList();
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
      return data.map((chatData) => _parseOpenWebUIChat(chatData)).toList();
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
    // Normalize to a List<Conversation> using our safe parser.
    if (data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map((e) => _parseOpenWebUIChat(e))
          .toList();
    }
    if (data is Map<String, dynamic>) {
      final list = (data['conversations'] ?? data['items'] ?? data['results']);
      if (list is List) {
        return list
            .whereType<Map<String, dynamic>>()
            .map((e) => _parseOpenWebUIChat(e))
            .toList();
      }
    }
    return <Conversation>[];
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
        return data.whereType<Map<String, dynamic>>().toList();
      }
      if (data is Map<String, dynamic>) {
        final list = (data['items'] ?? data['results'] ?? data['messages']);
        if (list is List) {
          return list.whereType<Map<String, dynamic>>().toList();
        }
      }
      return [];
    } on DioException catch (e) {
      // On any transport or other error, degrade gracefully without surfacing
      _traceApi('messages search request failed gracefully: ${e.type}');
      return [];
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
    return _parseFullOpenWebUIChat(response.data as Map<String, dynamic>);
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
      return data.map((chatData) => _parseOpenWebUIChat(chatData)).toList();
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
    return _parseFullOpenWebUIChat(response.data as Map<String, dynamic>);
  }

  // ==================== END ADVANCED CHAT FEATURES ====================

  // Legacy streaming wrapper methods removed
}
