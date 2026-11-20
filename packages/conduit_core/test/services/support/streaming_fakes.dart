import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/socket_health.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/streaming_helper.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';

/// Seconds since the epoch for every synthetic server message.
const int _serverTimestamp = 1767225600;

/// A persisted assistant message as `GET /api/v1/chats/:id` returns it.
Map<String, dynamic> serverAssistantMessage({
  String id = 'msg-1',
  String content = '',
  bool done = true,
  bool? isStreaming,
  Map<String, dynamic>? error,
  List<Map<String, dynamic>>? output,
  List<String>? followUps,
}) => {
  'id': id,
  'role': 'assistant',
  'content': content,
  'timestamp': _serverTimestamp,
  'done': done,
  'isStreaming': ?isStreaming,
  'error': ?error,
  'output': ?output,
  'followUps': ?followUps,
};

/// A persisted user message as `GET /api/v1/chats/:id` returns it.
Map<String, dynamic> serverUserMessage({
  String id = 'user-1',
  required String content,
}) => {
  'id': id,
  'role': 'user',
  'content': content,
  'timestamp': _serverTimestamp,
};

/// A chat snapshot holding [messages].
Map<String, dynamic> serverChat(List<Map<String, dynamic>> messages) => {
  'id': 'conv-1',
  'title': 'Chat',
  'created_at': _serverTimestamp,
  'updated_at': _serverTimestamp,
  'chat': {'messages': messages},
};

/// Answers `GET /api/v1/chats/conv-1` from [responses] in order, repeating
/// the last one. A [FakeChatServer.failure] entry answers 500. Every other
/// request gets an empty JSON object.
class FakeChatServer implements HttpClientAdapter {
  FakeChatServer(this.responses, {this.latency = Duration.zero});

  /// Marks a response that fails with a server error.
  static const Object failure = Object();

  final List<Object> responses;

  /// How long each chat fetch takes to answer, on the test's clock.
  final Duration latency;

  int chatFetches = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    if (options.method == 'GET' && options.path == '/api/v1/chats/conv-1') {
      final index = chatFetches < responses.length
          ? chatFetches
          : responses.length - 1;
      chatFetches++;
      if (latency > Duration.zero) await Future<void>.delayed(latency);
      final response = responses[index];
      if (identical(response, failure)) {
        return ResponseBody.fromString('{}', 500, headers: _json);
      }
      return ResponseBody.fromString(jsonEncode(response), 200, headers: _json);
    }
    return ResponseBody.fromString('{}', 200, headers: _json);
  }

  static const _json = {
    'content-type': ['application/json'],
  };

  @override
  void close({bool force = false}) {}
}

/// An [ApiService] whose requests [server] answers.
ApiService fakeApi(FakeChatServer server) {
  final api = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
  );
  api.dio.httpClientAdapter = server;
  api.dio.interceptors.clear();
  return api;
}

/// The socket facts a stream reads (foreground, whether the transport may be
/// kept, the connected session) and the signals it listens to, all set by
/// the test. Setting a fact emits nothing on its own except
/// [transportPolicyChanges], as [SocketService] does; a test emits health
/// and reconnect signals where the real service would.
class FakeStreamSocket implements SocketService {
  bool _foreground = true;
  bool _keepable = true;
  bool _connected = true;
  String? _sessionId = 'sess-1';

  SocketChatEventHandler? _chatHandler;
  SocketChatEventHandler? _lastChatHandler;
  SocketChannelEventHandler? _channelHandler;
  int chatSubscriptionDisposeCount = 0;
  int channelSubscriptionDisposeCount = 0;

  /// Each `(conversationId, sessionId)` the stream moved its handlers to.
  final sessionUpdates = <(String, String)>[];

  final _health = StreamController<SocketHealth>.broadcast();
  final _reconnects = StreamController<void>.broadcast();
  final _policy = StreamController<void>.broadcast();

  @override
  bool get isAppForeground => _foreground;

  @override
  bool get mayMaintainTransport => _keepable;

  @override
  bool get isConnected => _connected;

  @override
  String? get sessionId => _connected ? _sessionId : null;

  @override
  Stream<SocketHealth> get healthStream => _health.stream;

  @override
  Stream<void> get onReconnect => _reconnects.stream;

  @override
  Stream<void> get transportPolicyChanges => _policy.stream;

  bool get hasChatHandler => _chatHandler != null;

  void setTransport({
    bool? foreground,
    bool? keepable,
    bool? connected,
    String? sessionId,
  }) {
    final policyChanged =
        (foreground != null && foreground != _foreground) ||
        (keepable != null && keepable != _keepable);
    _foreground = foreground ?? _foreground;
    _keepable = keepable ?? _keepable;
    _connected = connected ?? _connected;
    _sessionId = sessionId ?? _sessionId;
    if (policyChanged) _policy.add(null);
  }

  void emitHealth() => _health.add(
    SocketHealth(
      latencyMs: -1,
      isConnected: _connected,
      transport: 'websocket',
      reconnectCount: 0,
    ),
  );

  void emitReconnect() => _reconnects.add(null);

  final List<({Set<String> aliases, List<Map<String, dynamic>> events})>
  _bufferScopes = [];

  /// Holds a frame that arrives before any chat handler exists, in a scope
  /// named by the frame's own chat, session and message ids, as
  /// SocketService buffers it.
  void bufferChatEvent(
    String type,
    Object? payload, {
    String? messageId,
    String? sessionId,
    String? chatId,
  }) {
    final aliases = _aliases(chatId, sessionId, messageId);
    final scope = _bufferScopes
        .where((scope) => scope.aliases.any(aliases.contains))
        .firstOrNull;
    final event = _event(type, payload, messageId, sessionId, chatId);
    if (scope == null) {
      _bufferScopes.add((aliases: aliases, events: [event]));
    } else {
      scope.aliases.addAll(aliases);
      scope.events.add(event);
    }
  }

  static Set<String> _aliases(
    String? chatId,
    String? sessionId,
    String? messageId,
  ) => {
    if (chatId != null) 'chat:$chatId',
    if (sessionId != null) 'session:$sessionId',
    if (messageId != null) 'message:$messageId',
  };

  void emitChatEvent(
    String type,
    Object? payload, {
    String? messageId,
    String? sessionId,
    String? chatId,
  }) => _chatHandler?.call(
    _event(type, payload, messageId, sessionId, chatId),
    null,
  );

  /// Delivers through the last chat handler even after it was disposed, as an
  /// event already queued when the stream was torn down.
  void emitQueuedChatEvent(String type, Object? payload, {String? messageId}) =>
      _lastChatHandler?.call(
        _event(type, payload, messageId, null, null),
        null,
      );

  void emitChannelEvent(
    String type,
    Object? payload, {
    String? messageId,
    String? sessionId,
    String? chatId,
  }) => _channelHandler?.call(
    _event(type, payload, messageId, sessionId, chatId),
    null,
  );

  static Map<String, dynamic> _event(
    String type,
    Object? payload,
    String? messageId,
    String? sessionId,
    String? chatId,
  ) => {
    'data': {'type': type, 'data': payload},
    'message_id': ?messageId,
    'session_id': ?sessionId,
    'chat_id': ?chatId,
  };

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    bool keepsAliveInBackground = false,
    SocketReplayGapCallback? onReplayGap,
    required SocketChatEventHandler handler,
  }) {
    _chatHandler = handler;
    _lastChatHandler = handler;
    // As SocketService's replay: the first scope sharing an alias with this
    // registration, by chat, then session, then message, replayed whole.
    final wanted = _aliases(conversationId, sessionId, messageId);
    for (final alias in wanted) {
      final scope = _bufferScopes
          .where((scope) => scope.aliases.contains(alias))
          .firstOrNull;
      if (scope == null) continue;
      _bufferScopes.remove(scope);
      for (final event in scope.events) {
        handler(event, null);
      }
      break;
    }
    return SocketEventSubscription(() {
      chatSubscriptionDisposeCount++;
      _chatHandler = null;
    }, handlerId: 'chat');
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    _channelHandler = handler;
    return SocketEventSubscription(() {
      channelSubscriptionDisposeCount++;
      _channelHandler = null;
    }, handlerId: 'channel');
  }

  @override
  void updateSessionIdForConversation(
    String conversationId,
    String newSessionId,
  ) => sessionUpdates.add((conversationId, newSessionId));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The chat state a stream writes through its callbacks.
class RecordedStream {
  RecordedStream({String content = '', String? userPrompt})
    : messages = [
        if (userPrompt != null)
          ChatMessage(
            id: 'user-1',
            role: 'user',
            content: userPrompt,
            timestamp: DateTime.utc(2026),
          ),
        ChatMessage(
          id: 'msg-1',
          role: 'assistant',
          content: content,
          timestamp: DateTime.utc(2026),
          isStreaming: true,
        ),
      ];

  List<ChatMessage> messages;
  int finishCount = 0;

  /// Each server message id the stream bound to its reply, in order.
  final remoteBindings = <String>[];

  ChatMessage get reply => messages.last;

  void _updateLast(ChatMessage Function(ChatMessage) update) {
    messages = [...messages.sublist(0, messages.length - 1), update(reply)];
  }

  void _updateById(String id, ChatMessage Function(ChatMessage) update) {
    final index = messages.indexWhere((message) => message.id == id);
    if (index == -1) return;
    messages = [
      ...messages.take(index),
      update(messages[index]),
      ...messages.skip(index + 1),
    ];
  }

  void _finish() {
    finishCount++;
    _updateLast((message) => message.copyWith(isStreaming: false));
  }
}

/// Attaches a task-socket stream for message `msg-1` in chat `conv-1`, whose
/// socket session is `sess-1`, and returns what it writes. With [userPrompt]
/// the reply follows a user message `user-1` that asked it.
({RecordedStream log, ActiveChatStream stream}) attachTaskSocketStream({
  required ApiService api,
  required FakeStreamSocket socket,
  String chatId = 'conv-1',
  String initialContent = '',
  String? userPrompt,
  bool allowForeignMessageBinding = true,
  Future<void> Function()? abort,
}) {
  final log = RecordedStream(content: initialContent, userPrompt: userPrompt);
  final stream = attachUnifiedChunkedStreaming(
    session: ChatCompletionSession.taskSocket(
      messageId: 'msg-1',
      sessionId: 'sess-1',
      conversationId: chatId,
      taskId: 'task-1',
      abort: abort,
    ),
    webSearchEnabled: false,
    assistantMessageId: 'msg-1',
    modelId: 'test-model',
    modelItem: const <String, dynamic>{},
    sessionId: 'sess-1',
    activeConversationId: chatId,
    api: api,
    socketService: socket,
    workerManager: WorkerManager(maxConcurrentTasks: 1),
    allowForeignMessageBinding: allowForeignMessageBinding,
    onRemoteMessageBound: log.remoteBindings.add,
    appendToLastMessage: (chunk) => log._updateLast(
      (message) => message.copyWith(content: message.content + chunk),
    ),
    bufferLastMessageContent: (content) =>
        log._updateLast((message) => message.copyWith(content: content)),
    replaceLastMessageContent: (content) =>
        log._updateLast((message) => message.copyWith(content: content)),
    updateLastMessageWith: log._updateLast,
    appendStatusUpdate: (_, _) {},
    upsertCodeExecution: (_, _) {},
    appendSourceReference: (_, _) {},
    updateMessageById: log._updateById,
    completeStreamingUi: () {},
    finishStreaming: log._finish,
    getMessages: () => log.messages,
    getVisibleStreamingContent: () => null,
    flushStreamingBuffer: () {},
  );
  return (log: log, stream: stream);
}
