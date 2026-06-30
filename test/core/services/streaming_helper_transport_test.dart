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
  List<Map<String, dynamic>>? pollResponses,
}) {
  final api = ApiService(
    serverConfig: const ServerConfig(
      id: 'test',
      name: 'Test',
      url: 'http://localhost:0',
    ),
    workerManager: WorkerManager(),
  );
  api.dio.httpClientAdapter = _StubAdapter(
    pollResponse: pollResponse,
    pollResponses: pollResponses,
  );
  api.dio.interceptors.clear();
  return api;
}

/// Adapter that optionally returns a canned poll response.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter({this.pollResponse, this.pollResponses});

  final Map<String, dynamic>? pollResponse;
  final List<Map<String, dynamic>>? pollResponses;
  final requests = <({String method, String path})>[];
  var _getResponseIndex = 0;

  int requestCount({required String method, required String path}) {
    return requests
        .where((request) => request.method == method && request.path == path)
        .length;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    requests.add((method: options.method, path: options.path));
    if (options.method == 'GET') {
      if (pollResponses != null && pollResponses!.isNotEmpty) {
        final responseIndex = _getResponseIndex < pollResponses!.length
            ? _getResponseIndex
            : pollResponses!.length - 1;
        _getResponseIndex++;
        return ResponseBody(
          Stream.value(utf8.encode(jsonEncode(pollResponses![responseIndex]))),
          200,
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
      if (pollResponse != null) {
        return ResponseBody(
          Stream.value(utf8.encode(jsonEncode(pollResponse))),
          200,
          headers: {
            'content-type': ['application/json'],
          },
        );
      }
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

Map<String, dynamic> _serverAssistantMessage({
  String id = 'msg-1',
  String content = '',
  bool done = true,
  Map<String, dynamic>? error,
  List<String>? followUps,
  List<Map<String, dynamic>>? statusHistory,
  List<Map<String, dynamic>>? sources,
  Map<String, dynamic>? usage,
  Map<String, dynamic>? metadata,
}) {
  return {
    'id': id,
    'role': 'assistant',
    'content': content,
    'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'done': done,
    'error': ?error,
    'follow_ups': ?followUps,
    'statusHistory': ?statusHistory,
    'sources': ?sources,
    'usage': ?usage,
    'metadata': ?metadata,
  };
}

Map<String, dynamic> _serverUserMessage({
  required String id,
  required String content,
}) {
  return {
    'id': id,
    'role': 'user',
    'content': content,
    'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
  };
}

Map<String, dynamic> _serverConversationResponse({
  required List<Map<String, dynamic>> messages,
  String id = 'conv-1',
  String title = 'Chat',
}) {
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    'id': id,
    'title': title,
    'created_at': timestamp,
    'updated_at': timestamp,
    'chat': {'messages': messages},
  };
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
  final codeExecutions = <(String, ChatCodeExecution)>[];
  final sourceReferences = <(String, ChatSourceReference)>[];
  final messageByIdUpdates = <(String, ChatMessage Function(ChatMessage))>[];
  int messageByIdMutationCount = 0;
  int uiFinishCount = 0;
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

  void appendStatusUpdate(String id, ChatStatusUpdate u) {
    statusUpdates.add((id, u));
  }

  void upsertCodeExecution(String id, ChatCodeExecution e) {
    codeExecutions.add((id, e));
  }

  void appendSourceReference(String id, ChatSourceReference r) {
    sourceReferences.add((id, r));
  }

  void updateMessageById(String id, ChatMessage Function(ChatMessage) updater) {
    messageByIdUpdates.add((id, updater));
    final index = messages.indexWhere((message) => message.id == id);
    if (index == -1) {
      return;
    }
    final current = messages[index];
    final updated = updater(current);
    if (identical(updated, current)) {
      return;
    }
    messageByIdMutationCount++;
    messages = [...messages.take(index), updated, ...messages.skip(index + 1)];
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
    uiFinishCount++;
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
  SocketService? socketService,
  String? Function()? getVisibleStreamingContent,
  void Function()? flushStreamingBuffer,
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
    socketService: socketService,
    workerManager: workerManager ?? _fakeWorkerManager(),
    appendToLastMessage: log.appendToLastMessage,
    bufferLastMessageContent: log.bufferLastMessageContent,
    replaceLastMessageContent: log.replaceLastMessageContent,
    updateLastMessageWith: log.updateLastMessageWith,
    appendStatusUpdate: log.appendStatusUpdate,
    upsertCodeExecution: log.upsertCodeExecution,
    appendSourceReference: log.appendSourceReference,
    updateMessageById: log.updateMessageById,
    completeStreamingUi: log.completeStreamingUi,
    finishStreaming: log.finishStreaming,
    getMessages: log.getMessages,
    getVisibleStreamingContent: getVisibleStreamingContent ?? () => null,
    flushStreamingBuffer: flushStreamingBuffer ?? log.flushStreamingBuffer,
  );
}

// ---------------------------------------------------------------------------
// Socket event injection helper
// ---------------------------------------------------------------------------

/// Captures the chat event handler from attachUnifiedChunkedStreaming so
/// tests can inject socket events directly. Works with the mock
/// SocketService below.
class FakeSocketInjector {
  void Function(Map<String, dynamic>, void Function(dynamic)?)? _handler;
  final _channelHandlers = <String, void Function(dynamic)>{};

  bool get hasChatHandler => _handler != null;
  int get channelHandlerCount => _channelHandlers.length;

  /// Injects a socket chat event with the given [type] and [payload].
  void emitChatEvent(
    String type,
    dynamic payload, {
    String? messageId,
    String? sessionId,
  }) {
    final raw = <String, dynamic>{
      'data': {'type': type, 'data': payload},
      'message_id': ?messageId,
      'session_id': ?sessionId,
    };
    _handler?.call(raw, null);
  }

  /// Injects a raw channel event payload for a registered channel name.
  void emitChannelLine(String channel, dynamic payload) {
    _channelHandlers[channel]?.call(payload);
  }
}

/// Minimal mock SocketService that routes addChatEventHandler to a
/// [FakeSocketInjector] so tests can inject events without a real socket.
class _MockSocketService implements SocketService {
  _MockSocketService(this._injector);
  final FakeSocketInjector _injector;

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) {
    _injector._handler = handler;
    return SocketEventSubscription(
      () => _injector._handler = null,
      handlerId: 'test',
    );
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) => SocketEventSubscription(() {}, handlerId: 'test-ch');

  @override
  Stream<void> get onReconnect => const Stream.empty();

  @override
  bool get isConnected => true;

  @override
  String? get sessionId => 'test-session';

  @override
  void onEvent(String eventName, void Function(dynamic) handler) {
    _injector._channelHandlers[eventName] = handler;
  }

  @override
  void offEvent(String eventName) {
    _injector._channelHandlers.remove(eventName);
  }

  // Stubs for remaining SocketService interface
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
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
      final api = _buildFakeApi();
      final adapter = api.dio.httpClientAdapter as _StubAdapter;
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
        api: api,
      );

      // Allow stream processing
      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      check(log.appendedChunks).deepEquals(['Hello', ' world']);
      check(log.finishCount).equals(1);
      check(
        adapter.requestCount(method: 'POST', path: '/api/chat/completed'),
      ).equals(1);
    });

    test('httpStream renders output-only structured snapshots', () async {
      final log = _CallbackLog();
      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'Partial stream'},
              ],
            },
          ],
        }),
        _sseFrame({
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'Structured stream'},
              ],
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
      await Future<void>.delayed(const Duration(milliseconds: 10));

      check(
        log.replacedContents,
      ).deepEquals(['Partial stream', 'Structured stream']);
      check(log.messages.last.content).equals('Structured stream');
      check(log.finishCount).equals(1);
    });

    test(
      'httpStream does not duplicate mixed output and delta content',
      () async {
        final log = _CallbackLog();
        final byteStream = Stream<List<int>>.fromIterable([
          _sseFrame({
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'Hello'},
                ],
              },
            ],
            'choices': [
              {
                'delta': {'content': 'Hel'},
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
        await Future<void>.delayed(const Duration(milliseconds: 10));

        check(log.appendedChunks).deepEquals(['Hel']);
        check(log.messages.last.content).equals('Hello');
        check(log.finishCount).equals(1);
      },
    );

    test(
      'chat:completion tracks tool placeholders without string scans',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        final payload = {
          'tool_calls': [
            {
              'id': 'call-1',
              'function': {'name': 'search'},
            },
          ],
        };
        registrar.emitChatEvent('chat:completion', payload, messageId: 'msg-1');
        await pumpMicrotasks();
        registrar.emitChatEvent('chat:completion', payload, messageId: 'msg-1');
        await pumpMicrotasks();

        check(log.appendedChunks).length.equals(1);
        check(log.appendedChunks.single).contains('type="tool_calls"');
        check(log.appendedChunks.single).contains('name="search"');
      },
    );

    test('httpStream handles emitter delta and status events', () async {
      final log = _CallbackLog();
      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'event': {
            'type': 'chat:message:delta',
            'data': {'content': 'Hello'},
          },
        }),
        _sseFrame({
          'type': 'event:message:delta',
          'data': {'content': ' world'},
        }),
        _sseFrame({
          'type': 'message',
          'data': {'content': '!'},
        }),
        _sseFrame({
          'type': 'status',
          'data': {
            'action': 'knowledge_search',
            'description': 'Searching',
            'done': false,
          },
        }),
        _sseFrame({
          'type': 'event:status',
          'data': {
            'status': 'Generating image...',
            'description': 'Generating image...',
          },
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
        activeConversationId: 'local:temp',
      );

      await pumpMicrotasks();
      await pumpMicrotasks();
      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      check(log.appendedChunks).deepEquals(['Hello', ' world', '!']);
      check(lastMsg.content).equals('Hello world!');
      check(lastMsg.statusHistory.length).equals(2);
      check(lastMsg.statusHistory.first.description).equals('Searching');
      check(
        lastMsg.statusHistory.last.description,
      ).equals('Generating image...');
      check(lastMsg.metadata).isNotNull();
      check(lastMsg.metadata!['status']).equals('Generating image...');
      check(log.messageByIdUpdates.length).equals(2);
      check(log.finishCount).equals(1);
    });

    test(
      'httpStream converts reasoning deltas into upstream details blocks',
      () async {
        final log = _CallbackLog(
          initialMessages: fakeStreamingAssistantMessages(content: 'Intro'),
        );
        final byteStream = Stream<List<int>>.fromIterable([
          _sseFrame({
            'choices': [
              {
                'delta': {'reasoning_content': 'Plan\nFirst step'},
              },
            ],
          }),
          _sseFrame({
            'choices': [
              {
                'delta': {'content': 'Answer'},
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

        final finalContent = log.messages.last.content;

        check(log.appendedChunks).isEmpty();
        check(log.replacedContents.first).contains('done="false"');
        check(finalContent).equals(
          'Intro\n'
          '<details type="reasoning" done="true" duration="0">\n'
          '<summary>Thought for 0 seconds</summary>\n'
          '&gt; Plan\n'
          '&gt; First step\n'
          '</details>\n'
          'Answer',
        );
        check(finalContent).not((value) => value.contains('<think>'));
        check(log.finishCount).equals(1);
      },
    );

    test('httpStream finalizes reasoning-only responses on done', () async {
      final log = _CallbackLog();
      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'choices': [
            {
              'delta': {'reasoning_content': 'Plan'},
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

      check(log.messages.last.content).equals(
        '<details type="reasoning" done="true" duration="0">\n'
        '<summary>Thought for 0 seconds</summary>\n'
        '&gt; Plan\n'
        '</details>\n',
      );
      check(log.finishCount).equals(1);
    });

    test(
      'taskSocket normalizes reasoning deltas from chat completion events',
      () async {
        final log = _CallbackLog(
          initialMessages: fakeStreamingAssistantMessages(content: 'Intro'),
        );
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'reasoning_content': 'Plan\nFirst step'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Answer'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'done': true,
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        check(log.messages.last.content).equals(
          'Intro\n'
          '<details type="reasoning" done="true" duration="0">\n'
          '<summary>Thought for 0 seconds</summary>\n'
          '&gt; Plan\n'
          '&gt; First step\n'
          '</details>\n'
          'Answer',
        );
        check(log.finishCount).equals(1);
      },
    );

    test(
      'taskSocket channel stream finalizes reasoning-only responses on done',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('request:chat:completion', {
          'channel': 'chan-1',
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChannelLine(
          'chan-1',
          'data: {"choices":[{"delta":{"reasoning_content":"Plan"}}]}',
        );
        await pumpMicrotasks();

        registrar.emitChannelLine('chan-1', 'data: [DONE]');
        await pumpMicrotasks();

        check(log.messages.last.content).equals(
          '<details type="reasoning" done="true" duration="0">\n'
          '<summary>Thought for 0 seconds</summary>\n'
          '&gt; Plan\n'
          '</details>\n',
        );
        check(log.finishCount).equals(1);
      },
    );

    test(
      'taskSocket channel stream applies usage updates from data payloads',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('request:chat:completion', {
          'channel': 'chan-1',
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChannelLine(
          'chan-1',
          'data: {"usage":{"prompt_tokens":3,"completion_tokens":5}}',
        );
        await pumpMicrotasks();

        final usage = log.messages.last.usage;
        check(usage).isNotNull();
        check(usage!['prompt_tokens']).equals(3);
        check(usage['completion_tokens']).equals(5);
      },
    );

    test(
      'chat:completion batches output, usage, model, and sources once',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'message',
              'id': 'out-1',
              'status': 'complete',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': 'Structured output'},
              ],
            },
          ],
          'selected_model_id': 'gpt-4o',
          'usage': {'prompt_tokens': 3, 'completion_tokens': 5},
          'sources': [
            {
              'source': {'name': 'doc', 'url': 'https://example.com/doc'},
              'document': ['snippet'],
            },
          ],
        }, messageId: 'msg-1');

        await pumpMicrotasks();

        final lastMessage = log.messages.last;
        check(log.messageByIdMutationCount).equals(1);
        check(log.sourceReferences).isEmpty();
        check(lastMessage.output).has((it) => it?.length, 'length').equals(1);
        check(lastMessage.metadata).isNotNull();
        check(lastMessage.metadata!['selectedModelId']).equals('gpt-4o');
        check(lastMessage.metadata!['arena']).equals(true);
        expect(
          lastMessage.usage,
          equals({'prompt_tokens': 3, 'completion_tokens': 5}),
        );
        check(lastMessage.sources).has((it) => it.length, 'length').equals(1);
        check(lastMessage.sources.single.url).equals('https://example.com/doc');
      },
    );

    test(
      'chat:completion output snapshots replace visible empty content',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'content': '',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'first'},
              ],
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'final'},
              ],
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        check(log.replacedContents).deepEquals(['first', 'final']);
        check(log.messages.last.content).equals('final');
      },
    );

    test(
      'chat:completion output snapshot preserves streamed text with details',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Visible answer'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'function_call',
              'call_id': 'call-1',
              'name': 'search',
              'arguments': {'query': 'docs'},
            },
            {
              'type': 'function_call_output',
              'call_id': 'call-1',
              'output': 'tool result',
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        check(log.appendedChunks).deepEquals(['Visible answer']);
        check(log.replacedContents).has((it) => it.length, 'length').equals(1);
        check(log.messages.last.content).contains('Visible answer');
        check(log.messages.last.content).contains('<details type="tool_calls"');
        check(log.messages.last.content).contains('name="search"');
        check(
          log.messages.last.output,
        ).has((it) => it?.length, 'length').equals(2);
      },
    );

    test(
      'chat:completion text-only output snapshot completes streamed delta',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Hel'},
            },
          ],
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'Hello'},
              ],
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        check(log.appendedChunks).deepEquals(['Hel']);
        check(log.messages.last.content).equals('Hello');
        check(log.messages.last.output).isNotNull();
      },
    );

    test(
      'chat:completion text snapshot remains raw for later details',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': '2 < 3'},
              ],
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': '2 < 3 and 4 > 1'},
              ],
            },
            {
              'type': 'function_call',
              'call_id': 'call-1',
              'name': 'compare',
              'arguments': {'left': 2, 'right': 3},
            },
            {
              'type': 'function_call_output',
              'call_id': 'call-1',
              'output': 'true',
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        final content = log.messages.last.content;
        check(content).contains('2 &lt; 3 and 4 &gt; 1');
        check(content).not((it) => it.contains('&amp;lt;'));
        check(content).contains('<details type="tool_calls"');
      },
    );

    test(
      'chat:completion full structured snapshot keeps raw plain text',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': '2 < 3'},
              ],
            },
            {
              'type': 'reasoning',
              'status': 'completed',
              'summary': [
                {'type': 'summary_text', 'text': 'checked'},
              ],
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': '2 < 3'},
              ],
            },
            {
              'type': 'function_call',
              'call_id': 'call-1',
              'name': 'compare',
              'arguments': const <String, dynamic>{},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        final content = log.messages.last.content;
        check(content).contains('2 &lt; 3');
        check(content).not((it) => it.contains('&amp;lt;'));
        check(content).contains('<details type="tool_calls"');
      },
    );

    test(
      'chat:completion output snapshot replaces pending tool placeholder',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'tool_calls': [
            {
              'id': 'call-1',
              'function': {'name': 'search'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        check(log.messages.last.content).contains('<summary>Executing...');

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'function_call',
              'call_id': 'call-1',
              'name': 'search',
              'arguments': {'query': 'docs'},
            },
            {
              'type': 'function_call_output',
              'call_id': 'call-1',
              'output': 'tool result',
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        final content = log.messages.last.content;
        check(
          '<details type="tool_calls"'.allMatches(content).length,
        ).equals(1);
        check(content).contains('<summary>Tool Executed</summary>');
        check(content).contains('tool result');
        check(content).not((it) => it.contains('Executing...'));
        check(content).not((it) => it.contains('&lt;details'));
      },
    );

    test(
      'chat:completion content replacement lets pending tool status reappear',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        final toolCallPayload = {
          'tool_calls': [
            {
              'id': 'call-1',
              'function': {'name': 'search'},
            },
          ],
        };
        registrar.emitChatEvent(
          'chat:completion',
          toolCallPayload,
          messageId: 'msg-1',
        );
        await pumpMicrotasks();
        check(log.messages.last.content).contains('<summary>Executing...');

        registrar.emitChatEvent('chat:completion', {
          'content': 'intermediate answer',
        }, messageId: 'msg-1');
        await pumpMicrotasks();
        check(log.messages.last.content).equals('intermediate answer');

        registrar.emitChatEvent(
          'chat:completion',
          toolCallPayload,
          messageId: 'msg-1',
        );
        await pumpMicrotasks();
        check(log.messages.last.content).contains('<summary>Executing...');
      },
    );

    test(
      'chat:completion plain output clears stale pending tool details',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'content':
              '<details><summary>User details</summary>Keep me</details>\nFinal answer',
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'tool_calls': [
            {
              'id': 'call-1',
              'function': {'name': 'search'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();
        check(log.messages.last.content).contains('<summary>Executing...');

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'Final answer'},
              ],
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        final content = log.messages.last.content;
        check(content).contains('<details><summary>User details</summary>');
        check(content).contains('Keep me');
        check(content).contains('Final answer');
        check(content).not((it) => it.contains('Executing...'));
      },
    );

    test('chat:completion plain output replaces stale partial text', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      registrar.emitChatEvent('chat:completion', {
        'content': 'Partial',
      }, messageId: 'msg-1');
      await pumpMicrotasks();

      registrar.emitChatEvent('chat:completion', {
        'tool_calls': [
          {
            'id': 'call-1',
            'function': {'name': 'search'},
          },
        ],
      }, messageId: 'msg-1');
      await pumpMicrotasks();
      check(log.messages.last.content).contains('Partial');
      check(log.messages.last.content).contains('<summary>Executing...');

      registrar.emitChatEvent('chat:completion', {
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'Final answer'},
            ],
          },
        ],
      }, messageId: 'msg-1');
      await pumpMicrotasks();

      check(log.messages.last.content).equals('Final answer');
    });

    test(
      'chat:completion structured tool snapshot suppresses duplicate pending status',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'function_call',
              'call_id': 'call-1',
              'name': 'search',
              'arguments': {'query': 'docs'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'tool_calls': [
            {
              'id': 'call-1',
              'function': {'name': 'search'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        final content = log.messages.last.content;
        check(
          '<details type="tool_calls"'.allMatches(content).length,
        ).equals(1);
      },
    );

    test(
      'chat:completion output snapshot keeps answer after reasoning-only state',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'reasoning_content': 'thinking'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'output': [
            {
              'type': 'reasoning',
              'status': 'completed',
              'summary': [
                {'type': 'summary_text', 'text': 'thinking'},
              ],
            },
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'Final answer'},
              ],
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        check(log.messages.last.content).contains('<details type="reasoning"');
        check(log.messages.last.content).contains('Final answer');
      },
    );

    test(
      'chat:completion repeated output snapshots keep one details block',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Visible answer'},
            },
          ],
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        Map<String, Object?> outputPayload(String result) => {
          'output': [
            {
              'type': 'function_call',
              'call_id': 'call-1',
              'name': 'search',
              'arguments': {'query': 'docs'},
            },
            {
              'type': 'function_call_output',
              'call_id': 'call-1',
              'output': result,
            },
          ],
        };

        registrar.emitChatEvent(
          'chat:completion',
          outputPayload('first result'),
          messageId: 'msg-1',
        );
        await pumpMicrotasks();
        registrar.emitChatEvent(
          'chat:completion',
          outputPayload('second result'),
          messageId: 'msg-1',
        );
        await pumpMicrotasks();

        final content = log.messages.last.content;
        check(
          '<details type="tool_calls"'.allMatches(content).length,
        ).equals(1);
        check(content).contains('Visible answer');
        check(content).contains('second result');
        check(content).not((it) => it.contains('&lt;details'));
      },
    );

    test(
      'taskSocket channel stream preserves malformed payload fallback',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('request:chat:completion', {
          'channel': 'chan-1',
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        registrar.emitChannelLine('chan-1', 'data: {not json');
        await pumpMicrotasks();

        check(log.appendedChunks).deepEquals(['data: {not json']);
        check(log.messages.last.content).equals('data: {not json');

        registrar.emitChannelLine('chan-1', 'data: [DONE]');
        await pumpMicrotasks();

        check(log.finishCount).equals(1);
      },
    );

    test(
      'httpStream snapshot refresh preserves already visible follow-ups',
      () async {
        final log = _CallbackLog(
          initialMessages: [
            ChatMessage(
              id: 'msg-1',
              role: 'assistant',
              content: 'Answer',
              timestamp: DateTime.now(),
              isStreaming: true,
              followUps: const ['Ask again'],
            ),
          ],
        );
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [_serverAssistantMessage(content: 'Answer')],
          ),
        );

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([_sseDone()]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        // The post-completion snapshot refresh is an unawaited Future chain
        // (ensureChatCompletedSynced -> refreshConversationSnapshot) with no
        // production Timer of its own; against the fake API it settles on the
        // event queue. Pump microtasks repeatedly to let it complete instead of
        // waiting on a magic wall-clock delay that could silently fall out of
        // sync with production timing.
        for (var i = 0; i < 20; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(1);
        check(log.messages.last.followUps).deepEquals(['Ask again']);
      },
    );

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

    test('taskSocket keeps streaming open after terminal finish_reason '
        'until done arrives', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      registrar.emitChatEvent('chat:completion', {
        'choices': [
          {
            'delta': {'content': 'Hello there.'},
            'finish_reason': 'stop',
          },
        ],
      }, messageId: 'msg-1');

      await pumpMicrotasks();

      check(log.uiFinishCount).equals(0);
      check(log.finishCount).equals(0);
      check(log.messages.last.isStreaming).isTrue();
      check(log.messages.last.content).equals('Hello there.');
      expect(log.messages.last.metadata?['responseDone'], isTrue);

      registrar.emitChatEvent('chat:completion', {
        'content': 'Hello there.\n\nFinal answer',
      }, messageId: 'msg-1');

      await pumpMicrotasks();

      check(log.uiFinishCount).equals(0);
      check(log.finishCount).equals(0);
      check(log.messages.last.isStreaming).isTrue();
      check(log.messages.last.content).equals('Hello there.\n\nFinal answer');
      expect(log.messages.last.metadata?['responseDone'], isTrue);

      registrar.emitChatEvent('chat:message:follow_ups', {
        'follow_ups': ['Ask a follow-up'],
      }, messageId: 'msg-1');

      await pumpMicrotasks();

      check(log.messageByIdMutationCount).equals(2);
      check(log.messages.last.followUps).deepEquals(['Ask a follow-up']);
      check(log.messages.last.metadata).isNotNull();
      expect(
        log.messages.last.metadata!['followUps'],
        equals(['Ask a follow-up']),
      );
      check(log.uiFinishCount).equals(0);
      check(log.finishCount).equals(0);
      check(log.messages.last.isStreaming).isTrue();
      expect(log.messages.last.metadata?['responseDone'], isTrue);

      registrar.emitChatEvent('chat:completion', {
        'done': true,
      }, messageId: 'msg-1');

      await pumpMicrotasks();

      check(log.uiFinishCount).equals(0);
      check(log.finishCount).equals(1);
      check(log.messages.last.isStreaming).isFalse();
      expect(log.messages.last.metadata?['responseDone'], isTrue);
    });

    test(
      'taskSocket terminal finish_reason recovers when done is missed',
      () async {
        final previousDelay = debugTaskSocketTerminalRecoveryDelay;
        debugTaskSocketTerminalRecoveryDelay = const Duration(milliseconds: 10);
        addTearDown(() {
          debugTaskSocketTerminalRecoveryDelay = previousDelay;
        });

        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [
              _serverAssistantMessage(
                id: 'msg-1',
                content: 'Hello there.',
                done: true,
              ),
            ],
          ),
        );

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Hello there.'},
              'finish_reason': 'stop',
            },
          ],
        }, messageId: 'msg-1');

        await pumpMicrotasks();

        check(log.finishCount).equals(0);
        check(log.messages.last.isStreaming).isTrue();
        expect(log.messages.last.metadata?['responseDone'], isTrue);

        await Future<void>.delayed(const Duration(milliseconds: 30));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(1);
        check(log.messages.last.isStreaming).isFalse();
        expect(log.messages.last.content, equals('Hello there.'));
      },
    );

    test(
      'taskSocket HTTP completion starts poll recovery when socket events are missing',
      () async {
        final previousDelay = debugTaskSocketTerminalRecoveryDelay;
        debugTaskSocketTerminalRecoveryDelay = const Duration(milliseconds: 10);
        addTearDown(() {
          debugTaskSocketTerminalRecoveryDelay = previousDelay;
        });

        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [_serverAssistantMessage(content: 'Recovered from poll')],
          ),
        );
        final adapter = api.dio.httpClientAdapter as _StubAdapter;

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          socketService: _MockSocketService(registrar),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));

        check(
          adapter.requestCount(method: 'GET', path: '/api/v1/chats/conv-1'),
        ).isGreaterThan(0);
        check(log.messages.last.content).equals('Recovered from poll');
        check(log.finishCount).equals(1);
      },
    );

    test(
      'taskSocket terminal recovery keeps streaming open when polled snapshot is not done',
      () async {
        final previousDelay = debugTaskSocketTerminalRecoveryDelay;
        final previousLimit = debugTaskSocketStableNonTerminalRecoveryLimit;
        debugTaskSocketTerminalRecoveryDelay = const Duration(milliseconds: 10);
        debugTaskSocketStableNonTerminalRecoveryLimit = 4;
        addTearDown(() {
          debugTaskSocketTerminalRecoveryDelay = previousDelay;
          debugTaskSocketStableNonTerminalRecoveryLimit = previousLimit;
        });

        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': 'Hello there.',
                'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
                'done': false,
                'isStreaming': true,
              },
            ],
          ),
        );

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Hello there.'},
              'finish_reason': 'stop',
            },
          ],
        }, messageId: 'msg-1');

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(0);
        check(log.messages.last.isStreaming).isTrue();
        expect(log.messages.last.metadata?['responseDone'], isTrue);

        registrar.emitChatEvent('chat:message:follow_ups', {
          'follow_ups': ['Ask a follow-up'],
        }, messageId: 'msg-1');

        await pumpMicrotasks();

        check(log.finishCount).equals(0);
        check(log.messages.last.isStreaming).isTrue();
        check(log.messages.last.followUps).deepEquals(['Ask a follow-up']);

        registrar.emitChatEvent('chat:completion', {
          'done': true,
        }, messageId: 'msg-1');

        await pumpMicrotasks();

        check(log.finishCount).equals(1);
        check(log.messages.last.isStreaming).isFalse();
        check(log.messages.last.followUps).deepEquals(['Ask a follow-up']);
      },
    );

    test(
      'taskSocket terminal recovery keeps streaming open when poll is unavailable and follow-ups arrive late',
      () async {
        final previousDelay = debugTaskSocketTerminalRecoveryDelay;
        final previousLimit = debugTaskSocketStableNonTerminalRecoveryLimit;
        debugTaskSocketTerminalRecoveryDelay = const Duration(milliseconds: 10);
        debugTaskSocketStableNonTerminalRecoveryLimit = 6;
        addTearDown(() {
          debugTaskSocketTerminalRecoveryDelay = previousDelay;
          debugTaskSocketStableNonTerminalRecoveryLimit = previousLimit;
        });

        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'local:temp',
            taskId: 'task-1',
          ),
          log: log,
          activeConversationId: 'local:temp',
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Hello there.'},
              'finish_reason': 'stop',
            },
          ],
        }, messageId: 'msg-1');

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(0);
        check(log.messages.last.isStreaming).isTrue();
        expect(log.messages.last.metadata?['responseDone'], isTrue);

        registrar.emitChatEvent('chat:message:follow_ups', {
          'follow_ups': ['Ask a follow-up'],
        }, messageId: 'msg-1');

        await pumpMicrotasks();

        check(log.finishCount).equals(0);
        check(log.messages.last.isStreaming).isTrue();
        check(log.messages.last.followUps).deepEquals(['Ask a follow-up']);

        registrar.emitChatEvent('chat:completion', {
          'done': true,
        }, messageId: 'msg-1');

        await pumpMicrotasks();

        check(log.finishCount).equals(1);
        check(log.messages.last.isStreaming).isFalse();
        check(log.messages.last.followUps).deepEquals(['Ask a follow-up']);
      },
    );

    test(
      'taskSocket terminal recovery finishes once the poll-miss retry limit is exhausted',
      () async {
        final previousDelay = debugTaskSocketTerminalRecoveryDelay;
        final previousLimit = debugTaskSocketStableNonTerminalRecoveryLimit;
        debugTaskSocketTerminalRecoveryDelay = const Duration(milliseconds: 10);
        debugTaskSocketStableNonTerminalRecoveryLimit = 1;
        addTearDown(() {
          debugTaskSocketTerminalRecoveryDelay = previousDelay;
          debugTaskSocketStableNonTerminalRecoveryLimit = previousLimit;
        });

        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'local:temp',
            taskId: 'task-1',
          ),
          log: log,
          activeConversationId: 'local:temp',
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Hello there.'},
              'finish_reason': 'stop',
            },
          ],
        }, messageId: 'msg-1');

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        for (var i = 0; i < 20; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(1);
        check(log.messages.last.isStreaming).isFalse();
        check(log.messages.last.content).equals('Hello there.');
      },
    );

    test(
      'taskSocket terminal recovery eventually finishes after a stable non-terminal snapshot repeats',
      () async {
        final previousDelay = debugTaskSocketTerminalRecoveryDelay;
        final previousLimit = debugTaskSocketStableNonTerminalRecoveryLimit;
        debugTaskSocketTerminalRecoveryDelay = const Duration(milliseconds: 10);
        debugTaskSocketStableNonTerminalRecoveryLimit = 2;
        addTearDown(() {
          debugTaskSocketTerminalRecoveryDelay = previousDelay;
          debugTaskSocketStableNonTerminalRecoveryLimit = previousLimit;
        });

        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': 'Hello there.',
                'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
                'done': false,
                'isStreaming': true,
              },
            ],
          ),
        );

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent('chat:completion', {
          'choices': [
            {
              'delta': {'content': 'Hello there.'},
              'finish_reason': 'stop',
            },
          ],
        }, messageId: 'msg-1');

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        for (var i = 0; i < 6; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(1);
        check(log.messages.last.isStreaming).isFalse();
        check(log.messages.last.content).equals('Hello there.');
      },
    );

    test(
      'taskSocket HTTP completion recovery does not locally finish stable partial snapshots',
      () async {
        final previousDelay = debugTaskSocketTerminalRecoveryDelay;
        final previousLimit = debugTaskSocketStableNonTerminalRecoveryLimit;
        debugTaskSocketTerminalRecoveryDelay = const Duration(milliseconds: 10);
        debugTaskSocketStableNonTerminalRecoveryLimit = 2;
        addTearDown(() {
          debugTaskSocketTerminalRecoveryDelay = previousDelay;
          debugTaskSocketStableNonTerminalRecoveryLimit = previousLimit;
        });

        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [
              {
                'id': 'msg-1',
                'role': 'assistant',
                'content': 'Partial answer',
                'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
                'done': false,
                'isStreaming': true,
              },
            ],
          ),
        );

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        for (var i = 0; i < 8; i += 1) {
          await pumpMicrotasks();
        }

        check(log.messages.last.content).equals('Partial answer');
        check(log.finishCount).equals(0);
        check(log.messages.last.isStreaming).isTrue();

        registrar.emitChatEvent('chat:completion', {
          'done': true,
        }, messageId: 'msg-1');
        await pumpMicrotasks();

        check(log.finishCount).equals(1);
      },
    );

    test(
      'taskSocket binds alternate server message ids for the active session',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent(
          'chat:completion',
          {
            'choices': [
              {
                'delta': {'content': 'Bound content'},
              },
            ],
          },
          messageId: 'server-msg-1',
          sessionId: 'sess-1',
        );
        await pumpMicrotasks();

        registrar.emitChatEvent(
          'chat:message:follow_ups',
          {
            'follow_ups': ['Ask again'],
          },
          messageId: 'server-msg-1',
          sessionId: 'sess-1',
        );
        await pumpMicrotasks();

        registrar.emitChatEvent(
          'chat:completion',
          {'done': true},
          messageId: 'server-msg-1',
          sessionId: 'sess-1',
        );
        await pumpMicrotasks();

        check(log.messages.last.id).equals('msg-1');
        check(log.messages.last.content).equals('Bound content');
        check(log.messageByIdMutationCount).equals(1);
        check(log.messages.last.followUps).deepEquals(['Ask again']);
        check(log.messages.last.metadata).isNotNull();
        expect(log.messages.last.metadata!['followUps'], equals(['Ask again']));
        check(log.finishCount).equals(1);
      },
    );

    test(
      'taskSocket ignores alternate message ids from another session',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent(
          'chat:completion',
          {
            'choices': [
              {
                'delta': {'content': 'Should be ignored'},
              },
            ],
          },
          messageId: 'server-msg-1',
          sessionId: 'web-session',
        );

        await pumpMicrotasks();

        check(registrar.hasChatHandler).isTrue();
        check(log.messages.last.content).equals('');
        check(log.messages.last.followUps).isEmpty();
        check(log.messageByIdMutationCount).equals(0);
        check(log.finishCount).equals(0);
      },
    );

    test(
      'taskSocket retires stale helper when the local target is replaced',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            taskId: 'task-1',
          ),
          log: log,
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        check(registrar.hasChatHandler).isTrue();
        check(log.messages.last.isStreaming).isTrue();

        log.messages = [
          ChatMessage(
            id: 'msg-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime.now(),
            isStreaming: true,
          ),
          ChatMessage(
            id: 'user-2-local',
            role: 'user',
            content: 'New prompt',
            timestamp: DateTime.now(),
          ),
          ChatMessage(
            id: 'msg-2',
            role: 'assistant',
            content: '',
            timestamp: DateTime.now(),
            isStreaming: true,
          ),
        ];

        registrar.emitChatEvent(
          'chat:completion',
          {
            'choices': [
              {
                'delta': {'content': 'Old stream content'},
              },
            ],
          },
          messageId: 'msg-1',
          sessionId: 'sess-1',
        );

        await pumpMicrotasks();

        check(registrar.hasChatHandler).isFalse();
        check(log.finishCount).equals(0);
        check(log.messages.last.isStreaming).isTrue();
        check(log.messages.last.id).equals('msg-2');
        check(log.messages.last.content).equals('');

        registrar.emitChatEvent(
          'chat:message:follow_ups',
          {
            'follow_ups': ['Should not apply'],
          },
          messageId: 'msg-1',
          sessionId: 'sess-1',
        );

        await pumpMicrotasks();

        check(log.messages.last.followUps).isEmpty();
        check(log.messageByIdMutationCount).equals(0);
      },
    );

    test(
      'taskSocket ignores foreign-session follow-ups without syncing',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final api = _buildFakeApi();
        final adapter = api.dio.httpClientAdapter as _StubAdapter;

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        registrar.emitChatEvent(
          'chat:message:follow_ups',
          {
            'follow_ups': ['Ask a follow-up'],
          },
          messageId: 'msg-2',
          sessionId: 'web-session',
        );

        await pumpMicrotasks();
        await pumpMicrotasks();

        check(log.messages.last.followUps).isEmpty();
        check(log.messageByIdMutationCount).equals(0);
        check(registrar.hasChatHandler).isFalse();
        check(
          adapter.requestCount(method: 'POST', path: '/api/v1/chats/conv-1'),
        ).equals(0);
      },
    );

    test(
      'taskSocket ignores stale inactive recovery after retirement',
      () async {
        final log = _CallbackLog();
        final registrar = FakeSocketInjector();
        final api = _buildFakeApi(
          pollResponse: {
            'chat': {
              'messages': [
                {
                  'id': 'msg-1',
                  'content': 'Recovered stale content',
                  'done': true,
                },
              ],
            },
          },
        );
        final adapter = api.dio.httpClientAdapter as _StubAdapter;

        _attach(
          session: ChatCompletionSession.taskSocket(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            taskId: 'task-1',
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          socketService: _MockSocketService(registrar),
        );

        await pumpMicrotasks();

        log.messages = [
          ChatMessage(
            id: 'msg-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime.now(),
            isStreaming: true,
          ),
          ChatMessage(
            id: 'user-2-local',
            role: 'user',
            content: 'New prompt',
            timestamp: DateTime.now(),
          ),
          ChatMessage(
            id: 'msg-2',
            role: 'assistant',
            content: '',
            timestamp: DateTime.now(),
            isStreaming: true,
          ),
        ];

        registrar.emitChatEvent(
          'chat:completion',
          {
            'choices': [
              {
                'delta': {'content': 'Old stream content'},
              },
            ],
          },
          messageId: 'msg-1',
          sessionId: 'sess-1',
        );

        await pumpMicrotasks();
        check(registrar.hasChatHandler).isFalse();

        registrar.emitChatEvent('chat:active', {
          'active': false,
        }, sessionId: 'sess-1');

        await pumpMicrotasks();
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(log.messages.last.content).equals('');
        check(log.messages.last.isStreaming).isTrue();
        check(log.finishCount).equals(0);
        check(
          adapter.requestCount(method: 'GET', path: '/api/v1/chats/conv-1'),
        ).equals(0);
      },
    );

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

    test('jsonCompletion renders output-only payloads', () async {
      final log = _CallbackLog();

      _attach(
        session: ChatCompletionSession.jsonCompletion(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          jsonPayload: {
            'choices': [
              {
                'message': {'content': ''},
              },
            ],
            'output': [
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'Structured JSON reply'},
                ],
              },
            ],
          },
        ),
        log: log,
      );

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.replacedContents).deepEquals(['Structured JSON reply']);
      check(log.messages.last.content).equals('Structured JSON reply');
      check(log.messages.last.output).isNotNull();
      check(log.finishCount).equals(1);
    });

    test('jsonCompletion preserves content with structured details', () async {
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
            'output': [
              {
                'type': 'reasoning',
                'status': 'completed',
                'summary': [
                  {'type': 'summary_text', 'text': 'checked docs'},
                ],
              },
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': 'Direct reply'},
                ],
              },
            ],
          },
        ),
        log: log,
      );

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(log.messages.last.content).contains('<details type="reasoning"');
      check(log.messages.last.content).contains('Direct reply');
      check(
        'Direct reply'.allMatches(log.messages.last.content).length,
      ).equals(1);
      check(log.messages.last.output).isNotNull();
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

      check(log.messageByIdMutationCount).equals(1);
      check(log.messages.last.usage).isNotNull();
      check(log.messages.last.usage!['total_tokens']).equals(42);
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
      check(log.messageByIdMutationCount).equals(1);
      check(log.messages.last.error).isNotNull();
      check(log.messages.last.error!.content).equals('something broke');
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

      check(log.messageByIdMutationCount).equals(1);
      check(log.sourceReferences).isEmpty();
      check(
        log.messages.last.sources,
      ).has((it) => it.length, 'length').equals(1);
      check(log.messages.last.sources.single.url).equals('https://example.com');
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

      check(log.messageByIdMutationCount).equals(1);
      expect(
        log.messages.last.usage,
        equals({'prompt_tokens': 10, 'completion_tokens': 5}),
      );
    });

    test('httpStream applies usage and output from one frame', () async {
      final log = _CallbackLog();

      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'Structured with usage'},
              ],
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

      expect(
        log.messages.last.usage,
        equals({'prompt_tokens': 10, 'completion_tokens': 5}),
      );
      check(log.messages.last.content).equals('Structured with usage');
      check(log.messages.last.output).isNotNull();
      check(
        log.messages.last.output!,
      ).has((it) => it.length, 'length').equals(1);
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

      check(log.messageByIdMutationCount).equals(1);
      check(log.messages.last.metadata).isNotNull();
      check(log.messages.last.metadata!['selectedModelId']).equals('gpt-4o');
      check(log.messages.last.metadata!['arena']).equals(true);
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

      check(log.messageByIdMutationCount).equals(1);
      check(log.sourceReferences).isEmpty();
      check(
        log.messages.last.sources,
      ).has((it) => it.length, 'length').equals(1);
      check(log.messages.last.sources.single.url).equals('https://a.com');
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

      check(log.messageByIdMutationCount).equals(1);
      check(log.messages.last.error).isNotNull();
      check(log.messages.last.error!.content).equals('rate limited');
      check(log.finishCount).equals(1);
    });

    test('httpStream applies typed top-level error envelope', () async {
      final log = _CallbackLog();

      final byteStream = Stream<List<int>>.fromIterable([
        _sseFrame({
          'type': 'error',
          'error': {'message': 'typed rate limited'},
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
        activeConversationId: 'local:temp',
      );

      await pumpMicrotasks();
      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      check(lastMsg.error).isNotNull();
      check(lastMsg.error!.content).equals('typed rate limited');
      check(log.finishCount).equals(1);
    });

    test(
      'httpStream done recovery backfills delayed persisted error and snapshot state',
      () async {
        final log = _CallbackLog();
        final incompleteResponse = _serverConversationResponse(
          messages: [_serverAssistantMessage(content: '', followUps: const [])],
        );
        final persistedResponse = _serverConversationResponse(
          messages: [
            _serverAssistantMessage(
              content: '',
              error: const {'content': 'Persisted backend error'},
              followUps: const ['Ask again'],
              statusHistory: const [
                {'description': 'Searching', 'done': true},
              ],
              sources: const [
                {
                  'source': {'name': 'doc', 'url': 'https://example.com/doc'},
                  'document': ['snippet'],
                },
              ],
              usage: const {'prompt_tokens': 7, 'completion_tokens': 11},
              metadata: const {'serverFlag': true},
            ),
          ],
        );
        final api = _buildFakeApi(
          pollResponses: [
            incompleteResponse,
            persistedResponse,
            persistedResponse,
          ],
        );
        final adapter = api.dio.httpClientAdapter as _StubAdapter;

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([_sseDone()]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 2600));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        final lastMsg = log.messages.last;
        check(lastMsg.error).isNotNull();
        check(lastMsg.error!.content).equals('Persisted backend error');
        check(lastMsg.followUps).deepEquals(['Ask again']);
        check(lastMsg.statusHistory).has((it) => it.length, 'length').equals(1);
        check(lastMsg.statusHistory.single.description).equals('Searching');
        check(lastMsg.sources).has((it) => it.length, 'length').equals(1);
        check(lastMsg.sources.single.url).equals('https://example.com/doc');
        expect(
          lastMsg.usage,
          equals({'prompt_tokens': 7, 'completion_tokens': 11}),
        );
        check(lastMsg.metadata).isNotNull();
        check(lastMsg.metadata!['serverFlag']).equals(true);
        check(log.finishCount).equals(1);
        check(
          adapter.requestCount(method: 'GET', path: '/api/v1/chats/conv-1'),
        ).equals(3);
      },
    );

    test(
      'httpStream artifact-only done backfills delayed persisted text',
      () async {
        final log = _CallbackLog();
        final incompleteResponse = _serverConversationResponse(
          messages: [_serverAssistantMessage(content: '')],
        );
        final persistedResponse = _serverConversationResponse(
          messages: [_serverAssistantMessage(content: 'Final answer')],
        );
        final api = _buildFakeApi(
          pollResponses: [
            incompleteResponse,
            persistedResponse,
            persistedResponse,
          ],
        );

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([
              _sseFrame({
                'output': [
                  {
                    'type': 'message',
                    'id': 'out-1',
                    'status': 'complete',
                    'role': 'assistant',
                    'content': [
                      {'type': 'output_text', 'text': 'tool output'},
                    ],
                  },
                ],
              }),
              _sseDone(),
            ]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await pumpMicrotasks();

        check(log.finishCount).equals(1);
        check(log.messages.last.content).equals('tool output');

        await Future<void>.delayed(const Duration(milliseconds: 2600));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(log.messages.last.content).equals('Final answer');
        check(log.finishCount).equals(1);
      },
    );

    test(
      'httpStream event completion done avoids premature-end recovery without [DONE]',
      () async {
        final log = _CallbackLog();
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [_serverAssistantMessage(content: 'Recovered answer')],
          ),
        );
        final adapter = api.dio.httpClientAdapter as _StubAdapter;

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([
              _sseFrame({
                'type': 'chat:completion',
                'data': {'done': true},
              }),
            ]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await pumpMicrotasks();

        check(
          adapter.requestCount(method: 'GET', path: '/api/v1/chats/conv-1'),
        ).equals(0);
        check(log.finishCount).equals(0);
        check(log.messages.last.content).equals('');

        await Future<void>.delayed(const Duration(milliseconds: 2600));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(log.messages.last.content).equals('Recovered answer');
        check(log.finishCount).equals(1);
      },
    );

    test(
      'httpStream event completion done trusts visible streaming content before empty recovery checks',
      () async {
        final log = _CallbackLog();
        const visibleStreamingContent = 'Visible streamed answer';
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [_serverAssistantMessage(content: 'Recovered answer')],
          ),
        );
        final adapter = api.dio.httpClientAdapter as _StubAdapter;

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([
              _sseFrame({
                'type': 'chat:completion',
                'data': {'done': true},
              }),
            ]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          getVisibleStreamingContent: () => visibleStreamingContent,
        );

        await pumpMicrotasks();
        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await pumpMicrotasks();

        check(log.finishCount).equals(1);
        check(
          adapter.requestCount(method: 'GET', path: '/api/v1/chats/conv-1'),
        ).equals(0);
      },
    );

    test(
      'httpStream event completion done plus [DONE] only schedules completion side effects once',
      () async {
        final log = _CallbackLog();
        final incompleteResponse = _serverConversationResponse(
          messages: [_serverAssistantMessage(content: '')],
        );
        final persistedResponse = _serverConversationResponse(
          messages: [_serverAssistantMessage(content: 'Final answer')],
        );
        final api = _buildFakeApi(
          pollResponses: [
            incompleteResponse,
            persistedResponse,
            persistedResponse,
          ],
        );
        final adapter = api.dio.httpClientAdapter as _StubAdapter;

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([
              _sseFrame({
                'type': 'chat:completion',
                'data': {'done': true},
              }),
              _sseDone(),
            ]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await pumpMicrotasks();

        check(
          adapter.requestCount(method: 'POST', path: '/api/chat/completed'),
        ).equals(1);
        check(log.finishCount).equals(0);
        check(log.messages.last.content).equals('');

        await Future<void>.delayed(const Duration(milliseconds: 2600));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(
          adapter.requestCount(method: 'POST', path: '/api/chat/completed'),
        ).equals(1);
        check(
          adapter.requestCount(method: 'GET', path: '/api/v1/chats/conv-1'),
        ).equals(3);
        check(log.messages.last.content).equals('Final answer');
        check(log.finishCount).equals(1);
      },
    );

    test(
      'httpStream latest blank assistant does not adopt prior persisted answer when server has not created the new assistant yet',
      () async {
        final log = _CallbackLog(
          initialMessages: [
            ChatMessage(
              id: 'user-1',
              role: 'user',
              content: 'Old prompt',
              timestamp: DateTime.now(),
            ),
            ChatMessage(
              id: 'assistant-old',
              role: 'assistant',
              content: 'Old answer',
              timestamp: DateTime.now(),
            ),
            ChatMessage(
              id: 'user-2',
              role: 'user',
              content: 'New prompt',
              timestamp: DateTime.now(),
            ),
            ChatMessage(
              id: 'msg-2',
              role: 'assistant',
              content: '',
              timestamp: DateTime.now(),
              isStreaming: true,
            ),
          ],
        );
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [
              _serverUserMessage(id: 'server-user-1', content: 'Old prompt'),
              _serverAssistantMessage(
                id: 'server-assistant-old',
                content: 'Old answer',
                followUps: const ['Old follow-up'],
                statusHistory: const [
                  {'description': 'Old status'},
                ],
              ),
              _serverUserMessage(id: 'server-user-2', content: 'New prompt'),
            ],
          ),
        );

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-2',
            sessionId: 'sess-2',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([_sseDone()]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
          assistantMessageId: 'msg-2',
        );

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 2600));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(log.messages[1].content).equals('Old answer');
        check(log.messages[3].id).equals('msg-2');
        check(log.messages[3].content).equals('');
        check(log.messages[3].followUps).isEmpty();
        check(log.messages[3].statusHistory).isEmpty();
        check(log.finishCount).equals(1);
      },
    );

    test(
      'httpStream artifact-only done recovers original assistant after new prompt starts with partial local history and re-keyed ids',
      () async {
        final log = _CallbackLog();
        final incompleteResponse = _serverConversationResponse(
          messages: [_serverAssistantMessage(id: 'server-msg-1', content: '')],
        );
        final persistedResponse = _serverConversationResponse(
          messages: [
            _serverAssistantMessage(
              id: 'server-old-1',
              content: 'Older persisted answer that should stay untouched',
              followUps: const ['Older follow-up'],
              statusHistory: const [
                {'description': 'Older status'},
              ],
              sources: const [
                {
                  'source': {
                    'name': 'Older doc',
                    'url': 'https://example.com/older',
                  },
                  'document': ['Older snippet'],
                },
              ],
            ),
            _serverUserMessage(id: 'server-user-1', content: 'Old prompt'),
            _serverAssistantMessage(
              id: 'server-msg-1',
              content: 'Recovered A',
              followUps: const ['Recovered follow-up'],
              statusHistory: const [
                {'description': 'Recovered status'},
              ],
              sources: const [
                {
                  'source': {
                    'name': 'Recovered doc',
                    'url': 'https://example.com/recovered',
                  },
                  'document': ['Recovered snippet'],
                },
              ],
            ),
            _serverUserMessage(id: 'server-user-2', content: 'New prompt'),
            _serverAssistantMessage(
              id: 'server-msg-2',
              content: 'Newer reply',
              followUps: const ['Newer follow-up'],
            ),
          ],
        );
        final api = _buildFakeApi(
          pollResponses: [
            incompleteResponse,
            persistedResponse,
            persistedResponse,
          ],
        );

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([
              _sseFrame({
                'output': [
                  {
                    'type': 'message',
                    'id': 'out-1',
                    'status': 'complete',
                    'role': 'assistant',
                    'content': [
                      {'type': 'output_text', 'text': 'tool output'},
                    ],
                  },
                ],
              }),
              _sseDone(),
            ]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await pumpMicrotasks();

        log.messages = [
          ChatMessage(
            id: 'msg-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime.now(),
            isStreaming: true,
          ),
          ChatMessage(
            id: 'user-2-local',
            role: 'user',
            content: 'New prompt',
            timestamp: DateTime.now(),
          ),
          ChatMessage(
            id: 'msg-2',
            role: 'assistant',
            content: '',
            timestamp: DateTime.now(),
            isStreaming: true,
          ),
        ];

        await Future<void>.delayed(const Duration(milliseconds: 2600));
        for (var i = 0; i < 5; i++) {
          await pumpMicrotasks();
        }

        check(log.messages[0].id).equals('msg-1');
        check(log.messages[0].content).equals('Recovered A');
        check(log.messages[0].followUps).deepEquals(['Recovered follow-up']);
        check(
          log.messages[0].statusHistory,
        ).has((it) => it.length, 'length').equals(1);
        check(
          log.messages[0].statusHistory.single.description,
        ).equals('Recovered status');
        check(
          log.messages[0].sources,
        ).has((it) => it.length, 'length').equals(1);
        check(
          log.messages[0].sources.single.url,
        ).equals('https://example.com/recovered');
        check(log.messages[1].role).equals('user');
        check(log.messages[1].content).equals('New prompt');
        check(log.messages[2].id).equals('msg-2');
        check(log.messages[2].content).equals('');
        check(log.messages[2].followUps).isEmpty();
        check(log.messages[2].statusHistory).isEmpty();
        check(log.messages[2].sources).isEmpty();
        check(log.messages[2].isStreaming).isTrue();
      },
    );

    test(
      'httpStream snapshot refresh drops stale pending status rows after finish',
      () async {
        final log = _CallbackLog(
          initialMessages: [
            ChatMessage(
              id: 'msg-1',
              role: 'assistant',
              content: 'Answer',
              timestamp: DateTime.now(),
              isStreaming: true,
              statusHistory: const [
                ChatStatusUpdate(description: 'Searching...', done: false),
              ],
            ),
          ],
        );
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [_serverAssistantMessage(content: 'Answer')],
          ),
        );

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([_sseDone()]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        for (var i = 0; i < 3; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(1);
        check(log.messages.last.statusHistory).isEmpty();
      },
    );

    test(
      'httpStream snapshot refresh keeps status rows with unspecified done after finish',
      () async {
        final log = _CallbackLog(
          initialMessages: [
            ChatMessage(
              id: 'msg-1',
              role: 'assistant',
              content: 'Answer',
              timestamp: DateTime.now(),
              isStreaming: true,
              statusHistory: const [
                ChatStatusUpdate(description: 'Generating image...'),
              ],
            ),
          ],
        );
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [_serverAssistantMessage(content: 'Answer')],
          ),
        );

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([_sseDone()]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        for (var i = 0; i < 3; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(1);
        check(
          log.messages.last.statusHistory,
        ).has((it) => it.length, 'length').equals(1);
        check(
          log.messages.last.statusHistory.single.description,
        ).equals('Generating image...');
      },
    );

    test(
      'httpStream snapshot refresh clears stale sources after finish',
      () async {
        final log = _CallbackLog(
          initialMessages: [
            ChatMessage(
              id: 'msg-1',
              role: 'assistant',
              content: 'Answer',
              timestamp: DateTime.now(),
              isStreaming: true,
              sources: const [
                ChatSourceReference(
                  title: 'Stale source',
                  url: 'https://example.com/stale',
                ),
              ],
            ),
          ],
        );
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [_serverAssistantMessage(content: 'Answer')],
          ),
        );

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([_sseDone()]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        for (var i = 0; i < 3; i++) {
          await pumpMicrotasks();
        }

        check(log.finishCount).equals(1);
        check(log.messages.last.sources).isEmpty();
      },
    );

    test(
      'httpStream snapshot refresh batches follow-ups and metadata into one mutation',
      () async {
        final log = _CallbackLog(
          initialMessages: [
            ChatMessage(
              id: 'msg-1',
              role: 'assistant',
              content: 'Answer',
              timestamp: DateTime.now(),
              isStreaming: true,
            ),
          ],
        );
        final api = _buildFakeApi(
          pollResponse: _serverConversationResponse(
            messages: [
              _serverAssistantMessage(
                content: 'Answer',
                followUps: const ['Ask again'],
                statusHistory: const [
                  {'description': 'Searching', 'done': true},
                ],
                sources: const [
                  {
                    'source': {'name': 'doc', 'url': 'https://example.com/doc'},
                    'document': ['snippet'],
                  },
                ],
                usage: const {'prompt_tokens': 5, 'completion_tokens': 8},
                metadata: const {'serverFlag': true},
              ),
            ],
          ),
        );

        _attach(
          session: ChatCompletionSession.httpStream(
            messageId: 'msg-1',
            sessionId: 'sess-1',
            conversationId: 'conv-1',
            byteStream: Stream<List<int>>.fromIterable([_sseDone()]),
            abort: () async {},
          ),
          log: log,
          api: api,
          activeConversationId: 'conv-1',
        );

        await pumpMicrotasks();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        for (var i = 0; i < 3; i++) {
          await pumpMicrotasks();
        }

        final lastMsg = log.messages.last;
        check(log.finishCount).equals(1);
        check(log.messageByIdMutationCount).equals(1);
        check(lastMsg.followUps).deepEquals(['Ask again']);
        check(lastMsg.statusHistory).has((it) => it.length, 'length').equals(1);
        check(lastMsg.statusHistory.single.description).equals('Searching');
        check(lastMsg.sources).has((it) => it.length, 'length').equals(1);
        check(lastMsg.sources.single.url).equals('https://example.com/doc');
        expect(
          lastMsg.usage,
          equals({'prompt_tokens': 5, 'completion_tokens': 8}),
        );
        check(lastMsg.metadata).isNotNull();
        check(lastMsg.metadata!['serverFlag']).equals(true);
      },
    );

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

    test(
      'httpStream recovery preserves longer visible streaming content than stale server snapshots',
      () async {
        final log = _CallbackLog(
          initialMessages: fakeStreamingAssistantMessages(content: 'lagging'),
        );
        const visibleStreamingContent =
            'I am the newer visible streaming content';

        final byteStream = Stream<List<int>>.empty();
        final api = _buildFakeApi(
          pollResponse: {
            'chat': {
              'messages': [
                {'id': 'msg-1', 'content': 'short stale', 'done': true},
              ],
            },
          },
        );

        void flushVisibleStreamingBuffer() {
          log.flushStreamingBuffer();
          if (log.messages.isEmpty || log.messages.last.role != 'assistant') {
            return;
          }
          final last = log.messages.last;
          log.messages = [
            ...log.messages.sublist(0, log.messages.length - 1),
            last.copyWith(content: visibleStreamingContent),
          ];
        }

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
          getVisibleStreamingContent: () => visibleStreamingContent,
          flushStreamingBuffer: flushVisibleStreamingBuffer,
        );

        await pumpMicrotasks();
        for (var i = 0; i < 10; i++) {
          await pumpMicrotasks();
        }

        check(log.messages.last.content).equals(visibleStreamingContent);
        check(log.replacedContents).isEmpty();
      },
    );

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

  // =========================================================================
  // Socket event image normalization tests
  // =========================================================================
  group('socket event image normalization', () {
    // -----------------------------------------------------------------------
    // 11. chat:message:files normalizes and dedupes image URLs
    // -----------------------------------------------------------------------
    test('chat:message:files normalizes and dedupes image URLs', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      // Send duplicate image URLs via chat:message:files
      registrar.emitChatEvent('chat:message:files', {
        'files': [
          {'url': 'https://example.com/img1.png', 'type': 'image'},
          {'url': 'https://example.com/img2.png', 'type': 'file'},
          {'url': 'https://example.com/img1.png', 'type': 'image'},
        ],
      });

      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      check(lastMsg.files).isNotNull();
      // Should have exactly 2 images (deduplicated), both normalized
      // to {type: 'image', url: ...}
      check(lastMsg.files!.length).equals(2);
      check(
        lastMsg.files![0],
      ).deepEquals({'type': 'image', 'url': 'https://example.com/img1.png'});
      check(
        lastMsg.files![1],
      ).deepEquals({'type': 'image', 'url': 'https://example.com/img2.png'});
    });

    // -----------------------------------------------------------------------
    // 11b. 'files' event also normalizes and dedupes
    // -----------------------------------------------------------------------
    test('files event normalizes and dedupes image URLs', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      // Send files via the 'files' event type (raw payload, not
      // nested under 'files' key)
      registrar.emitChatEvent('files', [
        {'url': 'https://example.com/a.png'},
        {'url': 'https://example.com/b.png'},
        {'url': 'https://example.com/a.png'},
      ]);

      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      check(lastMsg.files).isNotNull();
      check(lastMsg.files!.length).equals(2);
      check(
        lastMsg.files![0],
      ).deepEquals({'type': 'image', 'url': 'https://example.com/a.png'});
      check(
        lastMsg.files![1],
      ).deepEquals({'type': 'image', 'url': 'https://example.com/b.png'});
    });

    // -----------------------------------------------------------------------
    // 11c. Both event types merge correctly in sequence
    // -----------------------------------------------------------------------
    test('chat:message:files then files event merges without dupes', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      // First batch via chat:message:files
      registrar.emitChatEvent('chat:message:files', {
        'files': [
          {'url': 'https://example.com/first.png'},
        ],
      });

      await pumpMicrotasks();

      // Second batch via files event (includes a dupe)
      registrar.emitChatEvent('files', [
        {'url': 'https://example.com/first.png'},
        {'url': 'https://example.com/second.png'},
      ]);

      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      check(lastMsg.files).isNotNull();
      // first.png should only appear once
      check(lastMsg.files!.length).equals(2);
      final urls = lastMsg.files!.map((f) => f['url']).toList();
      check(urls).deepEquals([
        'https://example.com/first.png',
        'https://example.com/second.png',
      ]);
    });

    test('chat:message:embeds replaces embeds from string payloads', () async {
      final log = _CallbackLog(
        initialMessages: [
          ChatMessage(
            id: 'msg-1',
            role: 'assistant',
            content: '',
            timestamp: DateTime.now(),
            isStreaming: true,
            embeds: const [
              {'src': '<div>stale</div>'},
            ],
          ),
        ],
      );
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      registrar.emitChatEvent('chat:message:embeds', {
        'embeds': ['<div>fresh</div>'],
      }, messageId: 'msg-1');

      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      check(lastMsg.embeds).isNotNull();
      check(lastMsg.embeds!).deepEquals([
        {'src': '<div>fresh</div>'},
      ]);
    });

    // -----------------------------------------------------------------------
    // 12. Status event before files — both land on same assistant message
    // -----------------------------------------------------------------------
    test('status event before files — both land on same message', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      // Status arrives first
      registrar.emitChatEvent('event:status', {
        'status': 'Generating image...',
      });

      await pumpMicrotasks();

      // Then files arrive
      registrar.emitChatEvent('files', {
        'files': [
          {'url': 'https://example.com/gen.png'},
        ],
      });

      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      // Status should have been applied
      check(lastMsg.metadata).isNotNull();
      check(lastMsg.metadata!['status']).equals('Generating image...');
      check(lastMsg.statusHistory.length).equals(1);
      check(lastMsg.statusHistory.single.occurredAt).isNotNull();
      check(log.messageByIdUpdates.length).equals(1);
      // Files should also be present
      check(lastMsg.files).isNotNull();
      check(lastMsg.files!.length).equals(1);
      check(lastMsg.files![0]['url']).equals('https://example.com/gen.png');
    });

    test('duplicate status events do not rewrite identical metadata', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();
      final statusPayload = <String, dynamic>{
        'action': 'knowledge_search',
        'description': 'Searching',
        'done': false,
      };

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      registrar.emitChatEvent('status', statusPayload);
      await pumpMicrotasks();

      check(log.messageByIdMutationCount).equals(1);

      registrar.emitChatEvent(
        'status',
        Map<String, dynamic>.from(statusPayload),
      );
      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      check(log.messageByIdMutationCount).equals(1);
      check(lastMsg.statusHistory.length).equals(1);
      check(lastMsg.statusHistory.single.description).equals('Searching');
      check(lastMsg.metadata).isNotNull();
      check(lastMsg.metadata!['status']).isA<Map<String, dynamic>>();
      check(
        (lastMsg.metadata!['status'] as Map<String, dynamic>)['description'],
      ).equals('Searching');
    });

    // -----------------------------------------------------------------------
    // 13. Partial success then terminal failure — files remain, error visible
    // -----------------------------------------------------------------------
    test('files remain on message after terminal error', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          taskId: 'task-1',
        ),
        log: log,
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      // Files arrive first (partial success)
      registrar.emitChatEvent('chat:message:files', {
        'files': [
          {'url': 'https://example.com/partial.png'},
        ],
      });

      await pumpMicrotasks();

      // Then terminal error
      registrar.emitChatEvent('chat:message:error', {
        'error': {'content': 'Generation failed halfway'},
      });

      await pumpMicrotasks();

      final lastMsg = log.messages.last;
      // Files from the partial success must still be present
      check(lastMsg.files).isNotNull();
      check(lastMsg.files!.length).equals(1);
      check(lastMsg.files![0]['url']).equals('https://example.com/partial.png');
      // Error must be recorded
      check(lastMsg.error).isNotNull();
      check(lastMsg.error!.content).equals('Generation failed halfway');
      // Streaming should have ended
      check(lastMsg.isStreaming).isFalse();
    });

    test('taskSocket inactive recovery finalizes persisted error '
        'without socket error event', () async {
      final log = _CallbackLog();
      final registrar = FakeSocketInjector();
      final api = _buildFakeApi(
        pollResponse: {
          'chat': {
            'messages': [
              {
                'id': 'msg-1',
                'error': {'content': 'Persisted backend error'},
              },
            ],
          },
        },
      );

      _attach(
        session: ChatCompletionSession.taskSocket(
          messageId: 'msg-1',
          sessionId: 'sess-1',
          conversationId: 'conv-1',
          taskId: 'task-1',
        ),
        log: log,
        api: api,
        activeConversationId: 'conv-1',
        socketService: _MockSocketService(registrar),
      );

      await pumpMicrotasks();

      registrar.emitChatEvent('chat:active', {'active': false});

      await pumpMicrotasks();
      for (var i = 0; i < 5; i++) {
        await pumpMicrotasks();
      }

      final lastMsg = log.messages.last;
      check(lastMsg.error).isNotNull();
      check(lastMsg.error!.content).equals('Persisted backend error');
      check(lastMsg.isStreaming).isFalse();
      check(log.finishCount).equals(1);
    });
  });
}
