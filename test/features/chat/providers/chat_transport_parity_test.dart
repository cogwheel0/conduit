import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/chat_completion_transport.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/core/services/streaming_helper.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/features/chat/services/chat_transport_dispatch.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

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
  int syncCalls = 0;

  @override
  Future<Map<String, dynamic>?> sendChatCompleted({
    required String chatId,
    required String messageId,
    required List<Map<String, dynamic>> messages,
    required String model,
    Map<String, dynamic>? modelItem,
    String? sessionId,
    List<String>? filterIds,
  }) async {
    chatCompletedCalls += 1;
    return const <String, dynamic>{};
  }

  @override
  Future<void> syncConversationMessages(
    String conversationId,
    List<ChatMessage> messages, {
    String? title,
    String? model,
    String? systemPrompt,
  }) async {
    syncCalls += 1;
  }
}

/// Adapter that optionally returns a canned poll response.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.pollResponse});

  final Map<String, dynamic>? pollResponse;
  final cancelledIds = <String>[];
  final stoppedTaskIds = <String>[];

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
    workerManager: workerManager ?? WorkerManager(maxConcurrentTasks: 1),
    appendToLastMessage: log.appendToLastMessage,
    replaceLastMessageContent: log.replaceLastMessageContent,
    updateLastMessageWith: log.updateLastMessageWith,
    appendStatusUpdate: (_, _) {},
    setFollowUps: (_, _) {},
    upsertCodeExecution: (_, _) {},
    appendSourceReference: (_, _) {},
    updateMessageById: log.updateMessageById,
    completeStreamingUi: log.completeStreamingUi,
    finishStreaming: log.finishStreaming,
    getMessages: log.getMessages,
    flushStreamingBuffer: log.flushStreamingBuffer,
  );
}

// ---------------------------------------------------------------------------
// Socket event injection helper
// ---------------------------------------------------------------------------

class FakeSocketInjector {
  final _registrations = <_ChatHandlerRegistration>[];

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
  Stream<void> get onReconnect => const Stream.empty();

  @override
  bool get isConnected => true;

  @override
  String? get sessionId => 'test-session';

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

    test(
      'taskSocket completion does not rewrite persisted chat history after chatCompleted',
      () async {
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
        check(api.syncCalls).equals(0);
      },
    );

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

    // -------------------------------------------------------------------
    // 6. Stop with no metadata doesn't crash
    // -------------------------------------------------------------------
    test('stop with no metadata is a no-op', () {
      final api = _buildFakeApi();

      final message = ChatMessage(
        id: 'msg-empty',
        role: 'assistant',
        content: 'partial...',
        timestamp: DateTime.now(),
        isStreaming: true,
      );

      // Should not throw
      stopActiveTransport(message, api);
      stopActiveTransport(message, null);
    });
  });

  group('writeTransportMetadata', () {
    // -------------------------------------------------------------------
    // 7. httpStream session writes correct transport metadata
    // -------------------------------------------------------------------
    test('writes httpStream transport metadata', () {
      // ignore: unused_local_variable – kept for parity with other tests
      final log = _CallbackLog();

      // Simulate writeTransportMetadata by manually applying the updaters
      // (since we can't easily set up a full provider container)
      final session = ChatCompletionSession.httpStream(
        messageId: 'msg-1',
        sessionId: 'sess-1',
        byteStream: const Stream.empty(),
        abort: () async {},
      );

      // The logic from writeTransportMetadata applied manually
      final meta = <String, dynamic>{};
      meta['transport'] = session.transport.name;
      if (session.taskId != null && session.taskId!.isNotEmpty) {
        meta['taskId'] = session.taskId;
      }
      if (session.abort != null) {
        meta['hasActiveAbortHandle'] = true;
      }

      check(meta['transport']).equals('httpStream');
      check(meta['hasActiveAbortHandle']).equals(true);
      check(meta).not((it) => it.containsKey('taskId'));
    });

    // -------------------------------------------------------------------
    // 8. taskSocket session writes correct transport metadata
    // -------------------------------------------------------------------
    test('writes taskSocket transport metadata', () {
      final session = ChatCompletionSession.taskSocket(
        messageId: 'msg-1',
        sessionId: 'sess-1',
        taskId: 'task-123',
      );

      final meta = <String, dynamic>{};
      meta['transport'] = session.transport.name;
      if (session.taskId != null && session.taskId!.isNotEmpty) {
        meta['taskId'] = session.taskId;
      }
      if (session.abort != null) {
        meta['hasActiveAbortHandle'] = true;
      }

      check(meta['transport']).equals('taskSocket');
      check(meta['taskId']).equals('task-123');
      check(meta).not((it) => it.containsKey('hasActiveAbortHandle'));
    });

    // -------------------------------------------------------------------
    // 9. jsonCompletion session writes correct transport metadata
    // -------------------------------------------------------------------
    test('writes jsonCompletion transport metadata', () {
      final session = ChatCompletionSession.jsonCompletion(
        messageId: 'msg-1',
        sessionId: 'sess-1',
        jsonPayload: const {'choices': []},
      );

      final meta = <String, dynamic>{};
      meta['transport'] = session.transport.name;
      if (session.taskId != null && session.taskId!.isNotEmpty) {
        meta['taskId'] = session.taskId;
      }
      if (session.abort != null) {
        meta['hasActiveAbortHandle'] = true;
      }

      check(meta['transport']).equals('jsonCompletion');
      check(meta).not((it) => it.containsKey('taskId'));
      check(meta).not((it) => it.containsKey('hasActiveAbortHandle'));
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
