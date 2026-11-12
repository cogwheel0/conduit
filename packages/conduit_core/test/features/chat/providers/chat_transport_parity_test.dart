import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/streaming_helper.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/features/chat/services/chat_transport_dispatch.dart';
import 'package:dio/dio.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fake helpers
// ---------------------------------------------------------------------------

/// Minimal [ApiService] for testing.
ApiService _buildFakeApi({Map<String, dynamic>? pollResponse}) {
  final api = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
  );
  api.dio.httpClientAdapter = _StubAdapter(pollResponse: pollResponse);
  api.dio.interceptors.clear();
  return api;
}

class _TrackingApiService extends ApiService {
  _TrackingApiService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'http://localhost:0',
        ),
        workerManager: WorkerManager(),
      );

  int chatCompletedCalls = 0;

  @override
  Future<Map<String, dynamic>?> sendChatCompleted({
    required String chatId,
    required String messageId,
    required List<Map<String, dynamic>> messages,
    required String model,
    Map<String, dynamic>? modelItem,
    String? sessionId,
    List<String>? filterIds,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    chatCompletedCalls += 1;
    return const <String, dynamic>{};
  }
}

/// Records every request's path, then lets [_inner] answer it.
class _PathRecordingAdapter implements HttpClientAdapter {
  _PathRecordingAdapter(this._inner);

  final HttpClientAdapter _inner;
  final paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) {
    paths.add(options.path);
    return _inner.fetch(options, requestStream, cancelOnError);
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

/// Adapter that optionally returns a canned poll response.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.pollResponse});

  final Map<String, dynamic>? pollResponse;
  final cancelledIds = <String>[];
  final stoppedTaskIds = <String>[];
  final stoppedChatIds = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    // Track task stop calls (path may include full URL or relative path)
    if (options.method == 'POST' && options.path.contains('/api/tasks/stop/')) {
      final taskId = options.path.split('/').last;
      stoppedTaskIds.add(taskId);
      return ResponseBody(
        Stream.value(utf8.encode('{"status": true}')),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }

    if (options.method == 'POST' &&
        options.path.contains('/api/tasks/chat/') &&
        options.path.endsWith('/stop')) {
      const prefix = '/api/tasks/chat/';
      const suffix = '/stop';
      final start = options.path.indexOf(prefix) + prefix.length;
      final end = options.path.length - suffix.length;
      stoppedChatIds.add(
        Uri.decodeComponent(options.path.substring(start, end)),
      );
      return ResponseBody(
        Stream.value(utf8.encode('{"status": true}')),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }

    if (pollResponse != null && options.method == 'GET') {
      return ResponseBody(
        Stream.value(utf8.encode(jsonEncode(pollResponse))),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }

    return ResponseBody(
      Stream.value(utf8.encode('{}')),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers Open WebUI 0.13's temporary chat resume with [status] and [body],
/// and records each request's chat id and session.
class _ResumeAdapter implements HttpClientAdapter {
  _ResumeAdapter({
    required int status,
    Map<String, dynamic> body = const {},
    List<({int status, Map<String, dynamic> body})>? answers,
  }) : _answers = answers ?? [(status: status, body: body)];

  /// One answer per resume in order; the last one repeats.
  final List<({int status, Map<String, dynamic> body})> _answers;

  /// Runs as each resume arrives, before it is answered.
  void Function()? onResume;
  final resumes = <({String chatId, Object? sessionId})>[];

  /// The path of every GET, such as a saved chat's poll.
  final reads = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    const prefix = '/api/tasks/chat/';
    const suffix = '/resume';
    if (options.method == 'POST' &&
        options.path.startsWith(prefix) &&
        options.path.endsWith(suffix)) {
      resumes.add((
        chatId: Uri.decodeComponent(
          options.path.substring(
            prefix.length,
            options.path.length - suffix.length,
          ),
        ),
        sessionId: (options.data as Map)['session_id'],
      ));
      onResume?.call();
      final answer = _answers[min(resumes.length, _answers.length) - 1];
      return ResponseBody(
        Stream.value(utf8.encode(jsonEncode(answer.body))),
        answer.status,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    if (options.method == 'GET') reads.add(options.path);
    return ResponseBody(
      Stream.value(utf8.encode('{}')),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Encodes a single SSE frame.
List<int> _sseFrame(Map<String, dynamic> json) {
  return utf8.encode('data: ${jsonEncode(json)}\n\n');
}

/// Encodes the [DONE] sentinel.
List<int> _sseDone() => utf8.encode('data: [DONE]\n\n');

/// Pumps microtask queue.
Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);

// ---------------------------------------------------------------------------
// Callback collector (reused pattern from streaming_helper_transport_test)
// ---------------------------------------------------------------------------

class _CallbackLog {
  final appendedChunks = <String>[];
  final replacedContents = <String>[];
  final messageUpdaters = <ChatMessage Function(ChatMessage)>[];
  int finishCount = 0;
  int flushCount = 0;

  List<ChatMessage> messages;

  _CallbackLog({List<ChatMessage>? initialMessages})
    : messages = initialMessages ?? _fakeStreamingMessages();

  void appendToLastMessage(String c) {
    appendedChunks.add(c);
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      final last = messages.last;
      messages = [
        ...messages.sublist(0, messages.length - 1),
        last.copyWith(content: last.content + c),
      ];
    }
  }

  void replaceLastMessageContent(String c) {
    replacedContents.add(c);
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      final last = messages.last;
      messages = [
        ...messages.sublist(0, messages.length - 1),
        last.copyWith(content: c),
      ];
    }
  }

  void bufferLastMessageContent(String c) {
    replaceLastMessageContent(c);
  }

  void updateLastMessageWith(ChatMessage Function(ChatMessage) updater) {
    messageUpdaters.add(updater);
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      final last = messages.last;
      messages = [...messages.sublist(0, messages.length - 1), updater(last)];
    }
  }

  void finishStreaming() {
    finishCount++;
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      final last = messages.last;
      messages = [
        ...messages.sublist(0, messages.length - 1),
        last.copyWith(isStreaming: false),
      ];
    }
  }

  void completeStreamingUi() {
    if (messages.isNotEmpty && messages.last.role == 'assistant') {
      final last = messages.last;
      messages = [
        ...messages.sublist(0, messages.length - 1),
        last.copyWith(isStreaming: false),
      ];
    }
  }

  List<ChatMessage> getMessages() => messages;

  void flushStreamingBuffer() {
    flushCount++;
  }

  void updateMessageById(
    String id,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    final index = messages.indexWhere((message) => message.id == id);
    if (index == -1) {
      return;
    }
    final updated = updater(messages[index]);
    messages = [...messages.take(index), updated, ...messages.skip(index + 1)];
  }
}

List<ChatMessage> _fakeStreamingMessages({
  String id = 'msg-1',
  String content = '',
  Map<String, dynamic>? metadata,
}) {
  return [
    ChatMessage(
      id: id,
      role: 'assistant',
      content: content,
      timestamp: DateTime.now(),
      isStreaming: true,
      metadata: metadata,
    ),
  ];
}

/// Helper: call attachUnifiedChunkedStreaming with minimal boilerplate.
ActiveChatStream _attach({
  required ChatCompletionSession session,
  required _CallbackLog log,
  ApiService? api,
  WorkerManager? workerManager,
  String assistantMessageId = 'msg-1',
  String sessionId = 'sess-1',
  String? activeConversationId = 'conv-1',
  SocketService? socketService,
  void Function(String? chatId, bool active)? onChatActiveChanged,
}) {
  return attachUnifiedChunkedStreaming(
    session: session,
    webSearchEnabled: false,
    assistantMessageId: assistantMessageId,
    modelId: 'test-model',
    modelItem: const <String, dynamic>{},
    sessionId: sessionId,
    activeConversationId: activeConversationId,
    api: api ?? _buildFakeApi(),
    socketService: socketService,
    onChatActiveChanged: onChatActiveChanged,
    workerManager: workerManager ?? WorkerManager(maxConcurrentTasks: 1),
    appendToLastMessage: log.appendToLastMessage,
    bufferLastMessageContent: log.bufferLastMessageContent,
    replaceLastMessageContent: log.replaceLastMessageContent,
    updateLastMessageWith: log.updateLastMessageWith,
    appendStatusUpdate: (_, _) {},
    upsertCodeExecution: (_, _) {},
    appendSourceReference: (_, _) {},
    updateMessageById: log.updateMessageById,
    completeStreamingUi: log.completeStreamingUi,
    finishStreaming: log.finishStreaming,
    getMessages: log.getMessages,
    getVisibleStreamingContent: () => null,
    flushStreamingBuffer: log.flushStreamingBuffer,
  );
}

// ---------------------------------------------------------------------------
// Socket event injection helper
// ---------------------------------------------------------------------------

class FakeSocketInjector {
  final _registrations = <_ChatHandlerRegistration>[];

  /// Fires the socket's reconnect signal; [sessionId] is the session it is
  /// connected as.
  final reconnects = StreamController<void>.broadcast();
  String sessionId = 'test-session';

  bool get hasChatHandler => _registrations.isNotEmpty;

  void emitChatEvent(
    String type,
    dynamic payload, {
    String? conversationId,
    String? messageId,
    String? sessionId,
  }) {
    final raw = <String, dynamic>{
      'chat_id': ?conversationId,
      'message_id': ?messageId,
      'session_id': ?sessionId,
      'data': {
        'type': type,
        'data': payload,
        'chat_id': ?conversationId,
        'message_id': ?messageId,
        'session_id': ?sessionId,
      },
    };
    for (final registration in List<_ChatHandlerRegistration>.from(
      _registrations,
    )) {
      if (!_shouldDeliver(
        registration.conversationId,
        registration.sessionId,
        registration.messageId,
        conversationId,
        sessionId,
        messageId,
        registration.requireFocus,
      )) {
        continue;
      }
      registration.handler(raw, null);
    }
  }
}

class _ChatHandlerRegistration {
  const _ChatHandlerRegistration({
    required this.id,
    required this.conversationId,
    required this.sessionId,
    required this.messageId,
    required this.requireFocus,
    required this.handler,
  });

  final String id;
  final String? conversationId;
  final String? sessionId;
  final String? messageId;
  final bool requireFocus;
  final SocketChatEventHandler handler;
}

bool _shouldDeliver(
  String? registeredConversationId,
  String? registeredSessionId,
  String? registeredMessageId,
  String? incomingConversationId,
  String? incomingSessionId,
  String? incomingMessageId,
  bool requireFocus,
) {
  final matchesConversation =
      registeredConversationId == null ||
      (incomingConversationId != null &&
          registeredConversationId == incomingConversationId);
  final matchesSession =
      registeredSessionId != null &&
      incomingSessionId != null &&
      registeredSessionId == incomingSessionId;
  final matchesMessage =
      registeredMessageId != null &&
      incomingMessageId != null &&
      registeredMessageId == incomingMessageId;

  if (!matchesConversation && !matchesSession && !matchesMessage) {
    return false;
  }

  if (!requireFocus) {
    return true;
  }

  return true;
}

class _MockSocketService implements SocketService {
  _MockSocketService(this._injector);

  final FakeSocketInjector _injector;
  var _nextHandlerId = 0;

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
    final handlerId = 'test-${_nextHandlerId++}';
    _injector._registrations.add(
      _ChatHandlerRegistration(
        id: handlerId,
        conversationId: conversationId,
        sessionId: sessionId,
        messageId: messageId,
        requireFocus: requireFocus,
        handler: handler,
      ),
    );
    return SocketEventSubscription(
      () => _injector._registrations.removeWhere(
        (registration) => registration.id == handlerId,
      ),
      handlerId: handlerId,
    );
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) => SocketEventSubscription(() {}, handlerId: 'test-channel');

  @override
  Stream<void> get onReconnect => _injector.reconnects.stream;

  @override
  bool get isConnected => true;

  @override
  String? get sessionId => _injector.sessionId;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Transport parity - direct streaming without socket', () {
    // -------------------------------------------------------------------
    // 1. Direct HTTP streaming works without a socket connection
    // -------------------------------------------------------------------
    test('httpStream works without socket connection', () async {
      final log = _CallbackLog();
      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'choices': [
            {
              'delta': {'content': 'Hello'},
            },
          ],
        }),
        _sseFrame({
          'choices': [
            {
              'delta': {'content': ' world'},
            },
          ],
        }),
        _sseDone(),
      ]);

      _attach(
        session: ChatCompletionSession.httpStream(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          byteStream: byteStream,
          abort: () async {},
        ),
        log: log,
      );

      // Allow stream processing
      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.appendedChunks).deepEquals(['Hello', ' world']);
      check(log.finishCount).equals(1);
    });

    test('a held reply never recovered ends the turn as unresolved, not as an '
        'empty answer, and nothing is sent again', () async {
      // Issue #848: a held completion whose saved reply the server never
      // finished while Conduit waited for it.
      final log = _CallbackLog();
      final api = _buildFakeApi();
      final requests = _PathRecordingAdapter(api.dio.httpClientAdapter);
      api.dio.httpClientAdapter = requests;

      _attach(
        session: ChatCompletionSession.httpStream(
          messageId: 'msg-1',
          conversationId: 'conv-1',
          byteStream: Stream<List<int>>.error(const HeldReplyUnresolved()),
          abort: () async {},
        ),
        log: log,
        api: api,
      );

      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();

      final reply = log.messages.single;
      check(reply.isStreaming).isFalse();
      check(reply.error?.content).equals(kHeldReplyUnresolvedMessage);
      check(isHeldReplyUnresolvedError(reply.error?.content)).isTrue();
      check(log.finishCount).equals(1);
      check(requests.paths).not((it) => it.contains('/api/chat/completions'));
    });

    test('taskSocket completion calls chatCompleted exactly once', () async {
      final api = _TrackingApiService();
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();
      final socket = _MockSocketService(registrar);

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          conversationId: 'conv-1',
          taskId: 'task-1',
        ),
        log: log,
        api: api,
        socketService: socket,
      );

      registrar.emitChatEvent(
        'chat:completion',
        {'content': 'Hello', 'done': true},
        conversationId: 'conv-1',
        sessionId: 'sess-1',
        messageId: 'msg-1',
      );

      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();

      check(api.chatCompletedCalls).equals(1);
    });

    // -------------------------------------------------------------------
    // 2. JSON completion works without a socket connection
    // -------------------------------------------------------------------
    test('jsonCompletion works without socket connection', () async {
      final log = _CallbackLog();

      _attach(
        session: ChatCompletionSession.jsonCompletion(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          jsonPayload: {
            'choices': [
              {
                'message': {'content': 'Full JSON response'},
              },
            ],
          },
        ),
        log: log,
      );

      await pumpMicrotasks();
      await pumpMicrotasks();

      // jsonCompletion replaces content
      check(log.replacedContents).isNotEmpty();
      check(log.replacedContents.last).equals('Full JSON response');
      check(log.finishCount).equals(1);
    });
  });

  group('Feature C — socket resume session shape', () {
    test('resume binds a foreign server message_id by chat_id '
        'when sessionId is null (REPLACE semantics)', () async {
      // Local placeholder id differs from the server's message_id. With a null
      // session id the helper must bind the foreign id via chat_id and apply
      // cumulative `content` as REPLACE onto the local message.
      final log = _CallbackLog(
        initialMessages: _fakeStreamingMessages(id: 'local-msg-1'),
      );
      final registrar = FakeSocketInjector();
      final socket = _MockSocketService(registrar);

      _attach(
        session: ChatCompletionSession.resumeSocket(
          messageId: 'local-msg-1',
          conversationId: 'conv-1',
        ),
        log: log,
        assistantMessageId: 'local-msg-1',
        // Force the helper into the resume registration mode (chat-id-only).
        sessionId: '',
        activeConversationId: 'conv-1',
        socketService: socket,
      );

      await pumpMicrotasks();

      // Cumulative REPLACE deltas carrying a *foreign* server message_id.
      registrar.emitChatEvent(
        'chat:completion',
        {'content': 'Hel'},
        conversationId: 'conv-1',
        messageId: 'server-msg-1',
      );
      await pumpMicrotasks();
      registrar.emitChatEvent(
        'chat:completion',
        {'content': 'Hello'},
        conversationId: 'conv-1',
        messageId: 'server-msg-1',
      );
      await pumpMicrotasks();

      // The local message id is preserved; cumulative content is the latest.
      check(log.messages.last.id).equals('local-msg-1');
      check(log.messages.last.content).equals('Hello');
      // The first snapshot replaces the local content; one that extends it
      // only streams its new text (issue #751), never a duplicate.
      check(log.replacedContents).deepEquals(['Hel']);
      check(log.appendedChunks).deepEquals(['lo']);

      registrar.emitChatEvent(
        'chat:completion',
        {'done': true},
        conversationId: 'conv-1',
        messageId: 'server-msg-1',
      );
      await pumpMicrotasks();

      check(log.finishCount).equals(1);
      check(log.messages.last.isStreaming).isFalse();
    });

    test('resume socket done finalizes exactly once (helper-layer '
        'idempotency)', () async {
      // Helper-layer guard: a single socket `done` for the resumed message must
      // produce exactly one finalize and leave the message settled. (The
      // notifier-level poll/socket double-finalize grace window is covered in
      // chat_messages_notifier_remote_sync_test.dart; this seam does not run
      // that poll.)
      final log = _CallbackLog(
        initialMessages: _fakeStreamingMessages(id: 'local-msg-1'),
      );
      final registrar = FakeSocketInjector();
      final socket = _MockSocketService(registrar);

      _attach(
        session: ChatCompletionSession.resumeSocket(
          messageId: 'local-msg-1',
          conversationId: 'conv-1',
        ),
        log: log,
        assistantMessageId: 'local-msg-1',
        sessionId: '',
        activeConversationId: 'conv-1',
        socketService: socket,
      );

      await pumpMicrotasks();

      registrar.emitChatEvent(
        'chat:completion',
        {'content': 'Hello', 'done': true},
        conversationId: 'conv-1',
        messageId: 'server-msg-1',
      );

      // Pump generously so any redundant recovery path would have a chance to
      // fire a second finalize.
      for (var i = 0; i < 10; i++) {
        await pumpMicrotasks();
      }

      check(log.finishCount).equals(1);
      check(log.messages.last.isStreaming).isFalse();
      check(log.messages.last.content).equals('Hello');
    });

    test('resume APPENDs choices[].delta.content increments', () async {
      final log = _CallbackLog(
        initialMessages: _fakeStreamingMessages(id: 'local-msg-1'),
      );
      final registrar = FakeSocketInjector();
      final socket = _MockSocketService(registrar);

      _attach(
        session: ChatCompletionSession.resumeSocket(
          messageId: 'local-msg-1',
          conversationId: 'conv-1',
        ),
        log: log,
        assistantMessageId: 'local-msg-1',
        sessionId: '',
        activeConversationId: 'conv-1',
        socketService: socket,
      );

      await pumpMicrotasks();

      registrar.emitChatEvent(
        'chat:completion',
        {
          'choices': [
            {
              'delta': {'content': 'He'},
            },
          ],
        },
        conversationId: 'conv-1',
        messageId: 'server-msg-1',
      );
      await pumpMicrotasks();
      registrar.emitChatEvent(
        'chat:completion',
        {
          'choices': [
            {
              'delta': {'content': 'llo'},
            },
          ],
        },
        conversationId: 'conv-1',
        messageId: 'server-msg-1',
      );
      await pumpMicrotasks();

      check(log.appendedChunks).deepEquals(['He', 'llo']);
      check(log.messages.last.content).equals('Hello');
    });

    test('resume APPEND deltas concatenate onto already-visible partial '
        'content (seed, no prefix loss or duplication)', () async {
      // The real resume scenario: the chat was opened already showing a partial
      // assistant response, and the live socket continues it with incremental
      // deltas. The rendered buffer must seed from the visible partial so the
      // first delta appends onto it rather than replacing or duplicating it.
      final log = _CallbackLog(
        initialMessages: _fakeStreamingMessages(
          id: 'local-msg-1',
          content: 'Par',
        ),
      );
      final registrar = FakeSocketInjector();
      final socket = _MockSocketService(registrar);

      _attach(
        session: ChatCompletionSession.resumeSocket(
          messageId: 'local-msg-1',
          conversationId: 'conv-1',
        ),
        log: log,
        assistantMessageId: 'local-msg-1',
        sessionId: '',
        activeConversationId: 'conv-1',
        socketService: socket,
      );

      await pumpMicrotasks();

      registrar.emitChatEvent(
        'chat:completion',
        {
          'choices': [
            {
              'delta': {'content': 'tial'},
            },
          ],
        },
        conversationId: 'conv-1',
        messageId: 'server-msg-1',
      );
      await pumpMicrotasks();

      // Only the new delta is appended; the already-visible 'Par' prefix is
      // preserved (not re-sent, not dropped).
      check(log.appendedChunks).deepEquals(['tial']);
      check(log.messages.last.content).equals('Partial');
    });
  });

  group('Sidebar indicator — optimistic START gating', () {
    ChatCompletionSession taskSocket({String? taskId = 'task-1'}) =>
        ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          conversationId: 'conv-1',
          taskId: taskId ?? '',
        );

    test('taskSocket with task id + persisted chat => true', () {
      check(
        shouldOptimisticallyMarkChatActive(
          session: taskSocket(),
          conversationId: 'conv-1',
        ),
      ).isTrue();
    });

    test('httpStream => false (no task_ids signal)', () {
      check(
        shouldOptimisticallyMarkChatActive(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            byteStream: const Stream.empty(),
            abort: () async {},
          ),
          conversationId: 'conv-1',
        ),
      ).isFalse();
    });

    test('jsonCompletion => false', () {
      check(
        shouldOptimisticallyMarkChatActive(
          session: ChatCompletionSession.jsonCompletion(
            messageId: 'msg-1',
            jsonPayload: const <String, dynamic>{},
          ),
          conversationId: 'conv-1',
        ),
      ).isFalse();
    });

    test('taskSocket with empty task id => false', () {
      check(
        shouldOptimisticallyMarkChatActive(
          session: taskSocket(taskId: ''),
          conversationId: 'conv-1',
        ),
      ).isFalse();
    });

    test('null / empty conversation id => false', () {
      check(
        shouldOptimisticallyMarkChatActive(
          session: taskSocket(),
          conversationId: null,
        ),
      ).isFalse();
      check(
        shouldOptimisticallyMarkChatActive(
          session: taskSocket(),
          conversationId: '',
        ),
      ).isFalse();
    });

    test('temporary chat => false', () {
      check(
        shouldOptimisticallyMarkChatActive(
          session: taskSocket(),
          conversationId: 'local:abc',
        ),
      ).isFalse();
    });
  });

  group('a temporary chat after the socket reconnects', () {
    // Open WebUI 0.13 sends a temporary chat's events only to the session
    // that owns it; the new session must take it over.
    const chatId = 'local:old-session:6f1c4b1e-1d7a-4c49-9a8d-6a1f3e2b9c10';

    Future<({_CallbackLog log, _ResumeAdapter server})> reconnect({
      int status = 200,
      Map<String, dynamic> body = const {},
      List<({int status, Map<String, dynamic> body})>? answers,
      String conversationId = chatId,
      void Function(FakeSocketInjector registrar)? duringResume,
      Duration settle = const Duration(milliseconds: 650),
    }) async {
      final server = _ResumeAdapter(
        status: status,
        body: body,
        answers: answers,
      );
      final api = _buildFakeApi()..dio.httpClientAdapter = server;
      final log = _CallbackLog(
        initialMessages: _fakeStreamingMessages(content: 'Hel'),
      );
      final registrar = FakeSocketInjector()..sessionId = 'old-session';
      addTearDown(registrar.reconnects.close);
      final stream = _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'old-session',
          conversationId: conversationId,
          taskId: 'task-1',
        ),
        log: log,
        api: api,
        sessionId: 'old-session',
        activeConversationId: conversationId,
        socketService: _MockSocketService(registrar),
      );
      addTearDown(() {
        for (final dispose in stream.socketSubscriptions) {
          dispose();
        }
        stream.disposeWatchdog();
      });
      if (duringResume != null) {
        server.onResume = () => duringResume(registrar);
      }
      registrar.sessionId = 'new-session';
      registrar.reconnects.add(null);
      // The recovery waits half a second for the socket to settle.
      await Future<void>.delayed(settle);
      return (log: log, server: server);
    }

    test('resumes it in the new session and keeps the running reply', () async {
      final result = await reconnect(
        status: 200,
        body: {
          'task_ids': ['task-1'],
          'streams': [
            {
              'chat_id': chatId,
              'message_id': 'msg-1',
              'output': [
                {
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    {'type': 'output_text', 'text': 'Hello there'},
                  ],
                },
              ],
              'content': 'Hello there',
            },
          ],
        },
      );

      check(result.server.resumes.single.chatId).equals(chatId);
      check(result.server.resumes.single.sessionId).equals('new-session');
      final reply = result.log.messages.single;
      check(reply.content).contains('Hello there');
      check(reply.isStreaming).isTrue();
      check(reply.error).isNull();
    });

    test('ends a reply the lost connection took with the server', () async {
      final result = await reconnect(
        status: 200,
        body: {'task_ids': <String>[], 'streams': <Object>[]},
      );

      final reply = result.log.messages.single;
      check(reply.isStreaming).isFalse();
      check(
        reply.error?.content,
      ).equals(TemporaryChatResume.connectionLostMessage);
      check(reply.content).equals('Hel');
    });

    test('ends the reply when the server no longer has the chat', () async {
      final result = await reconnect(
        status: 404,
        body: {'detail': TemporaryChatUnavailable.serverDetail},
      );

      final reply = result.log.messages.single;
      check(reply.isStreaming).isFalse();
      check(reply.error?.content).equals(TemporaryChatUnavailable.userMessage);
    });

    test('leaves the reply running when the session dropped before the '
        'server answered', () async {
      // The server refuses a session that is no longer connected; the chat
      // itself is fine, and the next reconnect asks again.
      final result = await reconnect(
        status: 404,
        body: {'detail': TemporaryChatUnavailable.serverDetail},
        duringResume: (registrar) => registrar.sessionId = 'newer-session',
      );

      final reply = result.log.messages.single;
      check(reply.isStreaming).isTrue();
      check(reply.error).isNull();
    });

    test('asks again after a failed request', () async {
      final result = await reconnect(
        answers: [
          (status: 502, body: {'detail': 'Bad Gateway'}),
          (
            status: 200,
            body: {
              'task_ids': <String>[],
              'streams': <Object>[],
            },
          ),
        ],
        // The second request follows a one second wait.
        settle: const Duration(milliseconds: 1900),
      );

      check(result.server.resumes).length.equals(2);
      check(
        result.log.messages.single.error?.content,
      ).equals(TemporaryChatResume.connectionLostMessage);
    });

    test('leaves the reply running on a server before 0.13', () async {
      // The path matches only the GET route that lists a chat's tasks.
      final result = await reconnect(
        status: 405,
        body: {'detail': 'Method Not Allowed'},
      );

      check(result.server.resumes).length.equals(1);
      final reply = result.log.messages.single;
      check(reply.isStreaming).isTrue();
      check(reply.error).isNull();
    });

    test('a saved chat is polled, not resumed', () async {
      final result = await reconnect(
        status: 200,
        conversationId: 'conv-1',
        body: {'task_ids': <String>[], 'streams': <Object>[]},
      );

      check(result.server.resumes).isEmpty();
      check(result.server.reads).contains('/api/v1/chats/conv-1');
    });

    test('an answer for a session that changed meanwhile is not applied', () async {
      final result = await reconnect(
        body: {'task_ids': <String>[], 'streams': <Object>[]},
        duringResume: (registrar) => registrar.sessionId = 'newer-session',
      );

      final reply = result.log.messages.single;
      check(reply.isStreaming).isTrue();
      check(reply.error).isNull();
    });
  });

  group('Sidebar indicator — paired setInactive on success/cancel/error', () {
    test(
      'chat:completion {done:true} fires onChatActiveChanged(chatId, false)',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final socket = _MockSocketService(registrar);
        final activeEvents = <(String?, bool)>[];

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: socket,
          onChatActiveChanged: (chatId, active) =>
              activeEvents.add((chatId, active)),
        );

        registrar.emitChatEvent(
          'chat:completion',
          {'content': 'Hello', 'done': true},
          conversationId: 'conv-1',
          sessionId: 'sess-1',
          messageId: 'msg-1',
        );

        await pumpMicrotasks();

        // The normal success finalize must clear the spinner directly, so a
        // dropped/late backend chat:active{false} cannot strand it. Symmetric
        // with the cancel + error branches.
        check(activeEvents).contains(('conv-1', false));
      },
    );

    test(
      'chat:tasks:cancel fires onChatActiveChanged(chatId, false)',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final socket = _MockSocketService(registrar);
        final activeEvents = <(String?, bool)>[];

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: socket,
          onChatActiveChanged: (chatId, active) =>
              activeEvents.add((chatId, active)),
        );

        registrar.emitChatEvent(
          'chat:tasks:cancel',
          <String, dynamic>{},
          conversationId: 'conv-1',
          sessionId: 'sess-1',
          messageId: 'msg-1',
        );

        await pumpMicrotasks();

        // The spinner must be cleared even if the backend's chat:active{false}
        // is never delivered (it only fires when the LAST task finishes).
        check(activeEvents).contains(('conv-1', false));
      },
    );

    test(
      'terminal chat:message:error fires onChatActiveChanged(chatId, false)',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final socket = _MockSocketService(registrar);
        final activeEvents = <(String?, bool)>[];

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: socket,
          onChatActiveChanged: (chatId, active) =>
              activeEvents.add((chatId, active)),
        );

        registrar.emitChatEvent(
          'chat:message:error',
          {
            'error': {'content': 'boom'},
            'done': true,
          },
          conversationId: 'conv-1',
          sessionId: 'sess-1',
          messageId: 'msg-1',
        );

        await pumpMicrotasks();

        check(activeEvents).contains(('conv-1', false));
      },
    );
  });

  group('Transport-aware stop', () {
    // -------------------------------------------------------------------
    // 3. Stop aborts direct HTTP streaming without task lookup
    // -------------------------------------------------------------------
    test('stop aborts httpStream via cancelStreamingMessage', () {
      final api = _buildFakeApi();
      // Register a cancel action to verify it gets called
      var abortCalled = false;
      api.registerLegacyCancelActionForTest('msg-http', () async {
        abortCalled = true;
      });

      final message = ChatMessage(
        id: 'msg-http',
        role: 'assistant',
        content: 'partial...',
        timestamp: DateTime.now(),
        isStreaming: true,
        metadata: const {
          'transport': 'httpStream',
          'hasActiveAbortHandle': true,
        },
      );

      stopActiveTransport(message, api);

      check(abortCalled).isTrue();
    });

    // -------------------------------------------------------------------
    // 4. Stop cancels taskSocket using task id
    // -------------------------------------------------------------------
    test('stop cancels taskSocket via stopTask', () async {
      final api = _buildFakeApi();
      final adapter = api.dio.httpClientAdapter as _StubAdapter;

      final message = ChatMessage(
        id: 'msg-task',
        role: 'assistant',
        content: 'partial...',
        timestamp: DateTime.now(),
        isStreaming: true,
        metadata: const {'transport': 'taskSocket', 'taskId': 'task-abc'},
      );

      stopActiveTransport(message, api);

      // Allow the unawaited future to complete (Dio request is async)
      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();

      check(adapter.stoppedTaskIds).deepEquals(['task-abc']);
    });

    test(
      'stop cancels taskSocket by chat when conversation metadata exists',
      () async {
        final api = _buildFakeApi();
        final adapter = api.dio.httpClientAdapter as _StubAdapter;

        final message = ChatMessage(
          id: 'msg-task-chat',
          role: 'assistant',
          content: 'partial...',
          timestamp: DateTime.now(),
          isStreaming: true,
          metadata: const {
            'transport': 'taskSocket',
            'taskId': 'task-abc',
            'taskConversationId': 'conv/with/slash',
          },
        );

        stopActiveTransport(message, api);

        await pumpMicrotasks();
        await pumpMicrotasks();
        await pumpMicrotasks();
        await pumpMicrotasks();
        await pumpMicrotasks();

        check(adapter.stoppedChatIds).deepEquals(['conv/with/slash']);
        check(adapter.stoppedTaskIds).isEmpty();
      },
    );

    // -------------------------------------------------------------------
    // 5. Stop cancels both abort handle and task id for mixed initiation
    // -------------------------------------------------------------------
    test('stop cancels both abort handle and task id', () async {
      final api = _buildFakeApi();
      final adapter = api.dio.httpClientAdapter as _StubAdapter;

      var abortCalled = false;
      api.registerLegacyCancelActionForTest('msg-mixed', () async {
        abortCalled = true;
      });

      final message = ChatMessage(
        id: 'msg-mixed',
        role: 'assistant',
        content: 'partial...',
        timestamp: DateTime.now(),
        isStreaming: true,
        metadata: const {
          'transport': 'httpStream',
          'hasActiveAbortHandle': true,
          'taskId': 'task-mixed',
        },
      );

      stopActiveTransport(message, api);

      // Allow the unawaited future to complete (Dio request is async)
      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();

      check(abortCalled).isTrue();
      check(adapter.stoppedTaskIds).deepEquals(['task-mixed']);
    });
  });

  // =========================================================================
  // Transport metadata survives image/status patches
  // =========================================================================
  group('transport metadata coexistence with image patches', () {
    // -------------------------------------------------------------------
    // 10. Image file patch preserves transport metadata
    // -------------------------------------------------------------------
    test('image file patch preserves transport metadata', () async {
      // Start with transport metadata already present (simulating
      // writeTransportMetadata having been called)
      final log = _CallbackLog(
        initialMessages: _fakeStreamingMessages(
          metadata: {'transport': 'taskSocket', 'taskId': 'task-abc'},
        ),
      );
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-abc',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      // Image files arrive via socket
      registrar.emitChatEvent('chat:message:files', {
        'files': [
          {'url': 'https://example.com/gen.png'},
        ],
      }, conversationId: 'conv-1');

      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      // Files should be present
      check(lastMsg.files).isNotNull();
      check(lastMsg.files!.length).equals(1);
      // Transport metadata must survive the file patch
      check(lastMsg.metadata).isNotNull();
      check(lastMsg.metadata!['transport']).equals('taskSocket');
      check(lastMsg.metadata!['taskId']).equals('task-abc');
    });

    // -------------------------------------------------------------------
    // 11. Status patch preserves transport metadata
    // -------------------------------------------------------------------
    test('status patch preserves transport metadata', () async {
      final log = _CallbackLog(
        initialMessages: _fakeStreamingMessages(
          metadata: {
            'transport': 'taskSocket',
            'taskId': 'task-xyz',
            'hasActiveAbortHandle': true,
          },
        ),
      );
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-xyz',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      // Status event arrives
      registrar.emitChatEvent('event:status', {
        'status': 'Processing...',
      }, conversationId: 'conv-1');

      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      // Status should be in metadata
      check(lastMsg.metadata).isNotNull();
      check(lastMsg.metadata!['status']).equals('Processing...');
      // Transport metadata must survive the status patch
      check(lastMsg.metadata!['transport']).equals('taskSocket');
      check(lastMsg.metadata!['taskId']).equals('task-xyz');
      check(lastMsg.metadata!['hasActiveAbortHandle']).equals(true);
    });

    test('scoped chat handler ignores unscoped socket events', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          conversationId: 'conv-1',
          taskId: 'task-routing',
        ),
        log: log,
        activeConversationId: 'conv-1',
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      check(registrar.hasChatHandler).isTrue();

      registrar.emitChatEvent('event:status', {'status': 'Should not route'});
      await pumpMicrotasks();

      check(log.messages.last.metadata).isNull();
    });

    // -------------------------------------------------------------------
    // 12. Sequential image + status patches preserve all metadata
    // -------------------------------------------------------------------
    test(
      'sequential image then status patches preserve all metadata',
      () async {
        final log = _CallbackLog(
          initialMessages: _fakeStreamingMessages(
            metadata: {'transport': 'taskSocket', 'taskId': 'task-seq'},
          ),
        );
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-seq',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        // Files first
        registrar.emitChatEvent('files', [
          {'url': 'https://example.com/seq.png'},
        ], conversationId: 'conv-1');

        await pumpMicrotasks();

        // Status second
        registrar.emitChatEvent('event:status', {
          'status': 'Done generating',
        }, conversationId: 'conv-1');

        await pumpMicrotasks();

        final lastMsg = log.messages.last;
        // Files
        check(lastMsg.files).isNotNull();
        check(lastMsg.files!.length).equals(1);
        // Status
        check(lastMsg.metadata!['status']).equals('Done generating');
        // Transport (must survive both patches)
        check(lastMsg.metadata!['transport']).equals('taskSocket');
        check(lastMsg.metadata!['taskId']).equals('task-seq');
      },
    );
  });
}
