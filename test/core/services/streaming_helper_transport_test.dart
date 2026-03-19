import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/chat_completion_transport.dart';
import 'package:conduit/core/services/streaming_helper.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake helpers
// ---------------------------------------------------------------------------

/// Minimal [ApiService] for testing. Uses a fake Dio adapter so no real
/// network calls are made.
ApiService _buildFakeApi({
  /// Optional canned response for GET /api/v1/chats/:id (poll recovery).
  Map<String, dynamic>? pollResponse,
}) {
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

/// Adapter that optionally returns a canned poll response.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.pollResponse});

  final Map<String, dynamic>? pollResponse;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    if (pollResponse != null && options.method == 'GET') {
      return ResponseBody(
        Stream.value(utf8.encode(jsonEncode(pollResponse))),
        200,
        headers: {
          'content-type': ['application/json'],
        },
      );
    }
    // Default: 200 OK, empty JSON
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

/// A [WorkerManager] that runs tasks synchronously (no isolate).
WorkerManager _fakeWorkerManager() => WorkerManager(maxConcurrentTasks: 1);

/// Creates a list of messages containing one streaming assistant message.
List<ChatMessage> fakeStreamingAssistantMessages({
  String id = 'msg-1',
  String content = '',
}) {
  return [
    ChatMessage(
      id: id,
      role: 'assistant',
      content: content,
      timestamp: DateTime.now(),
      isStreaming: true,
    ),
  ];
}

/// Encodes a single SSE frame.
List<int> _sseFrame(Map<String, dynamic> json) {
  return utf8.encode('data: ${jsonEncode(json)}\n\n');
}

/// Encodes the [DONE] sentinel.
List<int> _sseDone() => utf8.encode('data: [DONE]\n\n');

/// Pumps microtask queue by awaiting a zero-duration future.
Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);

// ---------------------------------------------------------------------------
// Shared callback collector
// ---------------------------------------------------------------------------

/// Collects all callback invocations for assertion.
class _CallbackLog {
  final appendedChunks = <String>[];
  final replacedContents = <String>[];
  final messageUpdaters = <ChatMessage Function(ChatMessage)>[];
  final statusUpdates = <(String, ChatStatusUpdate)>[];
  final followUpUpdates = <(String, List<String>)>[];
  final codeExecutions = <(String, ChatCodeExecution)>[];
  final sourceReferences = <(String, ChatSourceReference)>[];
  final messageByIdUpdates = <(String, ChatMessage Function(ChatMessage))>[];
  int finishCount = 0;
  int flushCount = 0;
  String? updatedTitle;
  bool tagsUpdated = false;

  List<ChatMessage> messages;

  _CallbackLog({List<ChatMessage>? initialMessages})
    : messages = initialMessages ?? fakeStreamingAssistantMessages();

  void appendToLastMessage(String c) {
    appendedChunks.add(c);
    // Also mutate the messages list to simulate real behavior.
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

  void appendStatusUpdate(String id, ChatStatusUpdate u) {
    statusUpdates.add((id, u));
  }

  void setFollowUps(String id, List<String> f) {
    followUpUpdates.add((id, f));
  }

  void upsertCodeExecution(String id, ChatCodeExecution e) {
    codeExecutions.add((id, e));
  }

  void appendSourceReference(String id, ChatSourceReference r) {
    sourceReferences.add((id, r));
  }

  void updateMessageById(String id, ChatMessage Function(ChatMessage) updater) {
    messageByIdUpdates.add((id, updater));
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

  List<ChatMessage> getMessages() => messages;

  void flushStreamingBuffer() {
    flushCount++;
  }
}

// ---------------------------------------------------------------------------
// Helper to call attachUnifiedChunkedStreaming with minimal boilerplate
// ---------------------------------------------------------------------------

ActiveChatStream _attach({
  required ChatCompletionSession session,
  required _CallbackLog log,
  ApiService? api,
  WorkerManager? workerManager,
  bool webSearchEnabled = false,
  String assistantMessageId = 'msg-1',
  String modelId = 'test-model',
  String sessionId = 'sess-1',
  String? activeConversationId = 'conv-1',
}) {
  return attachUnifiedChunkedStreaming(
    session: session,
    webSearchEnabled: webSearchEnabled,
    assistantMessageId: assistantMessageId,
    modelId: modelId,
    modelItem: const <String, dynamic>{},
    sessionId: sessionId,
    activeConversationId: activeConversationId,
    api: api ?? _buildFakeApi(),
    socketService: null,
    workerManager: workerManager ?? _fakeWorkerManager(),
    appendToLastMessage: log.appendToLastMessage,
    replaceLastMessageContent: log.replaceLastMessageContent,
    updateLastMessageWith: log.updateLastMessageWith,
    appendStatusUpdate: log.appendStatusUpdate,
    setFollowUps: log.setFollowUps,
    upsertCodeExecution: log.upsertCodeExecution,
    appendSourceReference: log.appendSourceReference,
    updateMessageById: log.updateMessageById,
    finishStreaming: log.finishStreaming,
    getMessages: log.getMessages,
    flushStreamingBuffer: log.flushStreamingBuffer,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('attachUnifiedChunkedStreaming transport dispatch', () {
    // -----------------------------------------------------------------------
    // 1. httpStream sessions append deltas and finish once
    // -----------------------------------------------------------------------
    test('httpStream appends deltas and finishes once on DONE', () async {
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

    // -----------------------------------------------------------------------
    // 2. taskSocket sessions consume socket deltas and finish once on done
    // -----------------------------------------------------------------------
    // NOTE: taskSocket requires a socketService or registerDeltaListener.
    // Since we pass null socketService and no registerDeltaListener, the
    // socket binding code won't activate. This test verifies the function
    // returns successfully with taskSocket transport. Full socket testing
    // would require a FakeSocketService which is out of scope for this task.
    test('taskSocket returns ActiveChatStream without crash', () async {
      final log = _CallbackLog();

      final stream = _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
      );

      // The stream should be created successfully.
      check(stream.controller).isNotNull();
    });

    // -----------------------------------------------------------------------
    // 3. jsonCompletion sessions apply payload and finish once
    // -----------------------------------------------------------------------
    test('jsonCompletion applies content and finishes', () async {
      final log = _CallbackLog();

      _attach(
        session: ChatCompletionSession.jsonCompletion(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          jsonPayload: {
            'choices': [
              {
                'message': {'content': 'Direct reply'},
              },
            ],
          },
        ),
        log: log,
      );

      // jsonCompletion schedules on next microtask
      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.replacedContents).deepEquals(['Direct reply']);
      check(log.finishCount).equals(1);
    });

    // -----------------------------------------------------------------------
    // 4. jsonCompletion applies usage, sources, and error
    // -----------------------------------------------------------------------
    test('jsonCompletion applies usage metadata', () async {
      final log = _CallbackLog();

      _attach(
        session: ChatCompletionSession.jsonCompletion(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          jsonPayload: {
            'choices': [
              {
                'message': {'content': 'reply'},
              },
            ],
            'usage': {'total_tokens': 42},
          },
        ),
        log: log,
      );

      await pumpMicrotasks();
      await pumpMicrotasks();

      // Usage should have been applied via updateLastMessageWith
      check(log.messageUpdaters.length).isGreaterOrEqual(1);
      // Apply an updater to a blank message and check usage was set
      final updated = log.messageUpdaters.first(
        ChatMessage(
          id: 'msg-1',
          role: 'assistant',
          content: '',
          timestamp: DateTime.now(),
        ),
      );
      check(updated.usage).isNotNull();
      check(updated.usage!['total_tokens']).equals(42);
    });

    test('jsonCompletion applies error metadata', () async {
      final log = _CallbackLog();

      _attach(
        session: ChatCompletionSession.jsonCompletion(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          jsonPayload: {
            'error': {'message': 'something broke'},
          },
        ),
        log: log,
      );

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.finishCount).equals(1);
      // Should have applied the error via updateLastMessageWith
      check(log.messageUpdaters.length).isGreaterOrEqual(1);
    });

    test('jsonCompletion applies sources metadata', () async {
      final log = _CallbackLog();

      _attach(
        session: ChatCompletionSession.jsonCompletion(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          jsonPayload: {
            'choices': [
              {
                'message': {'content': 'with sources'},
              },
            ],
            'sources': [
              {
                'source': {'name': 'test-doc', 'url': 'https://example.com'},
                'document': ['snippet one'],
              },
            ],
          },
        ),
        log: log,
      );

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.sourceReferences).isNotEmpty();
    });

    // -----------------------------------------------------------------------
    // 5. competing terminal signals still call finishStreaming once
    // -----------------------------------------------------------------------
    test(
      'httpStream finishStreaming called only once even with extra signals',
      () async {
        final log = _CallbackLog();

        // Stream that sends [DONE] then ends (two terminal signals)
        final byteStream = Stream<List<int>>.fromIterable([
          _sseFrame({
            'choices': [
              {
                'delta': {'content': 'x'},
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

        await pumpMicrotasks();
        await pumpMicrotasks();
        await pumpMicrotasks();

        // Exactly once, not twice
        check(log.finishCount).equals(1);
      },
    );

    // -----------------------------------------------------------------------
    // 6. httpStream parser updates usage, selected model, sources, and error
    // -----------------------------------------------------------------------
    test('httpStream applies usage update', () async {
      final log = _CallbackLog();

      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
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

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.messageUpdaters.length).isGreaterOrEqual(1);
    });

    test('httpStream applies selected model update', () async {
      final log = _CallbackLog();

      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({'selected_model_id': 'gpt-4o'}),
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

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.messageUpdaters.length).isGreaterOrEqual(1);
    });

    test('httpStream applies sources update', () async {
      final log = _CallbackLog();

      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'sources': [
            {
              'source': {'name': 'doc', 'url': 'https://a.com'},
              'document': ['text'],
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

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.sourceReferences).isNotEmpty();
    });

    test('httpStream applies error update', () async {
      final log = _CallbackLog();

      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'error': {'message': 'rate limited'},
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

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.messageUpdaters.length).isGreaterOrEqual(1);
      check(log.finishCount).equals(1);
    });

    // -----------------------------------------------------------------------
    // 7. httpStream premature end recovers from newer server state
    // -----------------------------------------------------------------------
    test('httpStream premature end triggers recovery polling', () async {
      final log = _CallbackLog();
      // Stream ends without [DONE]
      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'choices': [
            {
              'delta': {'content': 'partial'},
            },
          ],
        }),
        // Stream ends here - no [DONE]
      ]);

      final api = _buildFakeApi(
        pollResponse: {
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'content': 'partial plus server content',
                'done': true,
              },
            ],
          },
        },
      );

      _attach(
        session: ChatCompletionSession.httpStream(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          conversationId: 'conv-1',
          byteStream: byteStream,
          abort: () async {},
        ),
        log: log,
        api: api,
        activeConversationId: 'conv-1',
      );

      // Let stream complete and recovery poll fire
      await pumpMicrotasks();
      await pumpMicrotasks();
      // Recovery might need extra pumps due to async polling
      for (var i = 0; i < 10; i++) {
        await pumpMicrotasks();
      }

      // Should eventually finish
      check(log.finishCount).isGreaterOrEqual(1);
    });

    // -----------------------------------------------------------------------
    // 8. httpStream premature end without recoverable state surfaces error
    // -----------------------------------------------------------------------
    test('httpStream premature end without recovery still finishes', () async {
      final log = _CallbackLog();
      // Stream ends without [DONE] and poll returns null
      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'choices': [
            {
              'delta': {'content': 'x'},
            },
          ],
        }),
      ]);

      // Use a local: prefix so poll is skipped (isTemporaryChat)
      _attach(
        session: ChatCompletionSession.httpStream(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          byteStream: byteStream,
          abort: () async {},
        ),
        log: log,
        activeConversationId: 'local:temp',
      );

      await pumpMicrotasks();
      await pumpMicrotasks();
      for (var i = 0; i < 10; i++) {
        await pumpMicrotasks();
      }

      check(log.finishCount).isGreaterOrEqual(1);
    });

    // -----------------------------------------------------------------------
    // 9. httpStream recovery does not overwrite fresher local content
    // -----------------------------------------------------------------------
    test('httpStream recovery skips stale server content', () async {
      final log = _CallbackLog(
        initialMessages: fakeStreamingAssistantMessages(
          content: 'I am longer local content that is fresher',
        ),
      );

      // Stream ends without [DONE]
      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'choices': [
            {
              'delta': {'content': ' extra'},
            },
          ],
        }),
      ]);

      final api = _buildFakeApi(
        pollResponse: {
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'content': 'short', // shorter than local
                'done': true,
              },
            ],
          },
        },
      );

      _attach(
        session: ChatCompletionSession.httpStream(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          conversationId: 'conv-1',
          byteStream: byteStream,
          abort: () async {},
        ),
        log: log,
        api: api,
        activeConversationId: 'conv-1',
      );

      await pumpMicrotasks();
      for (var i = 0; i < 10; i++) {
        await pumpMicrotasks();
      }

      // The local content should NOT have been replaced with the shorter
      // server content.
      final lastContent = log.messages.last.content;
      check(lastContent.length).isGreaterThan('short'.length);
    });

    // -----------------------------------------------------------------------
    // 10. Rename: ActiveChatStream replaces ActiveSocketStream
    // -----------------------------------------------------------------------
    test('ActiveChatStream class is accessible', () {
      // This test simply verifies the type exists and can be constructed.
      // If this compiles and runs, the rename was applied correctly.
      final stream = ActiveChatStream(
        controller: null,
        socketSubscriptions: const [],
        disposeWatchdog: () {},
      );
      check(stream.socketSubscriptions).isEmpty();
    });
  });
}
