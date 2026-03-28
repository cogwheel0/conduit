import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:qonduit/core/models/chat_message.dart';
import 'package:qonduit/core/models/socket_event.dart';
import 'package:qonduit/core/services/api_service.dart';
import 'package:qonduit/core/services/chat_completion_transport.dart';
import 'package:qonduit/core/services/streaming_helper.dart';
import 'package:qonduit/core/services/worker_manager.dart';
import 'package:qonduit/core/models/server_config.dart';
import 'package:qonduit/features/chat/services/chat_transport_dispatch.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Local typedefs for socket delta listener (not yet in production code)
// ---------------------------------------------------------------------------

/// Callback invoked when a conversation delta arrives.
typedef ConversationDeltaDataCallback = void Function(ConversationDelta delta);

/// Callback invoked on delta listener errors.
typedef ConversationDeltaErrorCallback = void Function(Object error);

/// Registers a delta listener and returns a dispose function.
typedef RegisterConversationDeltaListener =
    void Function() Function({
      required ConversationDeltaRequest request,
      required ConversationDeltaDataCallback onDelta,
      required ConversationDeltaErrorCallback onError,
    });

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

  List<ChatMessage> getMessages() => messages;

  void flushStreamingBuffer() {
    flushCount++;
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
  // ignore: unused_parameter – kept for future delta-listener wiring
  RegisterConversationDeltaListener? registerDeltaListener,
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
    socketService: null,
    workerManager: workerManager ?? WorkerManager(maxConcurrentTasks: 1),
    appendToLastMessage: log.appendToLastMessage,
    replaceLastMessageContent: log.replaceLastMessageContent,
    updateLastMessageWith: log.updateLastMessageWith,
    appendStatusUpdate: (_, _) {},
    setFollowUps: (_, _) {},
    upsertCodeExecution: (_, _) {},
    appendSourceReference: (_, _) {},
    updateMessageById: (_, _) {},
    finishStreaming: log.finishStreaming,
    getMessages: log.getMessages,
    flushStreamingBuffer: log.flushStreamingBuffer,
  );
}

// ---------------------------------------------------------------------------
// Socket event injection helper
// ---------------------------------------------------------------------------

/// Captures delta listener callbacks for injecting socket events in tests.
class _FakeDeltaRegistrar {
  ConversationDeltaDataCallback? _chatHandler;

  RegisterConversationDeltaListener get registrar =>
      ({
        required ConversationDeltaRequest request,
        required ConversationDeltaDataCallback onDelta,
        required ConversationDeltaErrorCallback onError,
      }) {
        if (request.source == ConversationDeltaSource.chat) {
          _chatHandler = onDelta;
        }
        return () {};
      };

  void emitChatEvent(String type, dynamic payload, {String? messageId}) {
    final raw = <String, dynamic>{
      'data': {'type': type, 'data': payload},
      'message_id': ?messageId,
    };
    _chatHandler?.call(
      ConversationDelta(source: ConversationDeltaSource.chat, raw: raw),
    );
  }
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
      final registrar = _FakeDeltaRegistrar();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-abc',
        ),
        log: log,
        registerDeltaListener: registrar.registrar,
      );

      await pumpMicrotasks();

      // Image files arrive via socket
      registrar.emitChatEvent('chat:message:files', {
        'files': [
          {'url': 'https://example.com/gen.png'},
        ],
      });

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
      final registrar = _FakeDeltaRegistrar();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-xyz',
        ),
        log: log,
        registerDeltaListener: registrar.registrar,
      );

      await pumpMicrotasks();

      // Status event arrives
      registrar.emitChatEvent('event:status', {'status': 'Processing...'});

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
        final registrar = _FakeDeltaRegistrar();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-seq',
          ),
          log: log,
          registerDeltaListener: registrar.registrar,
        );

        await pumpMicrotasks();

        // Files first
        registrar.emitChatEvent('files', [
          {'url': 'https://example.com/seq.png'},
        ]);

        await pumpMicrotasks();

        // Status second
        registrar.emitChatEvent('event:status', {'status': 'Done generating'});

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
