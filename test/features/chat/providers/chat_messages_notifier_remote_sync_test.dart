import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _RecordingConversations extends Conversations {
  Conversation? lastUpsertedConversation;
  bool? lastTrustFolderConversation;

  @override
  Future<List<Conversation>> build() async => const <Conversation>[];

  @override
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {}

  @override
  void upsertConversation(
    Conversation conversation, {
    bool trustFolderConversation = false,
  }) {
    lastUpsertedConversation = conversation;
    lastTrustFolderConversation = trustFolderConversation;
  }
}

class _FakeSocketService extends SocketService {
  _FakeSocketService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
      );

  final _handlers = <SocketChatEventHandler>[];
  String currentSessionId = 'local-session';

  @override
  String? get sessionId => currentSessionId;

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) {
    void wrapped(
      Map<String, dynamic> event,
      void Function(dynamic response)? ack,
    ) {
      if (conversationId != null &&
          _extractConversationId(event) != conversationId) {
        return;
      }
      handler(event, ack);
    }

    _handlers.add(wrapped);
    return SocketEventSubscription(
      () => _handlers.removeWhere((candidate) => identical(candidate, wrapped)),
    );
  }

  String? _extractConversationId(Map<String, dynamic> event) {
    String? candidate = event['chat_id']?.toString();

    final data = event['data'];
    if (candidate == null && data is Map) {
      candidate = data['chat_id']?.toString() ?? data['chatId']?.toString();

      final inner = data['data'];
      if (candidate == null && inner is Map) {
        candidate = inner['chat_id']?.toString() ?? inner['chatId']?.toString();
      }
    }

    return candidate;
  }

  void emitChatEvent({
    required String type,
    required Map<String, dynamic> payload,
    String? messageId,
  }) {
    final event = <String, dynamic>{
      'data': {'type': type, 'data': payload},
      'message_id': ?messageId,
    };
    for (final handler in List<SocketChatEventHandler>.from(_handlers)) {
      handler(event, null);
    }
  }
}

class _FakeApiService extends ApiService {
  _FakeApiService(this._conversation)
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  Conversation _conversation;

  set conversation(Conversation value) => _conversation = value;

  List<String> taskIds = const <String>[];

  int getConversationCalls = 0;

  @override
  Future<Conversation> getConversation(String id) async {
    getConversationCalls++;
    return _conversation;
  }

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async => taskIds;
}

ChatMessage _userMessage(String id, String content, DateTime timestamp) =>
    ChatMessage(id: id, role: 'user', content: content, timestamp: timestamp);

ChatMessage _assistantMessage(String id, String content, DateTime timestamp) =>
    ChatMessage(
      id: id,
      role: 'assistant',
      content: content,
      timestamp: timestamp,
    );

Conversation _conversation(
  String id,
  List<ChatMessage> messages,
  DateTime timestamp,
) {
  return Conversation(
    id: id,
    title: 'Test Chat',
    createdAt: timestamp,
    updatedAt: timestamp,
    messages: messages,
  );
}

Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatMessagesNotifier remote sync', () {
    test('adopts a fetched snapshot for the same conversation ID', () async {
      final timestamp = DateTime.now();
      final initialMessages = [
        _userMessage('user-1', 'Hello', timestamp),
        _assistantMessage('assistant-1', 'Draft answer', timestamp),
      ];
      final refreshedMessages = [
        _userMessage('user-1', 'Hello', timestamp),
        _assistantMessage('assistant-1', 'Final answer from web', timestamp),
      ];

      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', initialMessages, timestamp));

      check(container.read(chatMessagesProvider)).deepEquals(initialMessages);

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', refreshedMessages, timestamp));
      await pumpMicrotasks();

      check(container.read(chatMessagesProvider)).deepEquals(refreshedMessages);
    });

    test(
      'refreshes the open conversation when another client updates it',
      () async {
        final timestamp = DateTime.now();
        final initialMessages = [
          _userMessage('user-1', 'Hello', timestamp),
          _assistantMessage('assistant-1', 'Initial answer', timestamp),
        ];
        final refreshedMessages = [
          ...initialMessages,
          _userMessage('user-2', 'Sent from web', timestamp),
          _assistantMessage('assistant-2', 'Reply from web', timestamp),
        ];

        final socket = _FakeSocketService();
        final api = _FakeApiService(
          _conversation('chat-1', refreshedMessages, timestamp),
        );

        final container = ProviderContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            socketServiceProvider.overrideWithValue(socket),
            apiServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(container.dispose);

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', initialMessages, timestamp));

        check(container.read(chatMessagesProvider)).deepEquals(initialMessages);

        socket.emitChatEvent(
          type: 'chat:message',
          payload: {'chat_id': 'chat-1', 'session_id': 'web-session'},
        );

        await Future<void>.delayed(const Duration(milliseconds: 500));
        await pumpMicrotasks();

        check(
          container.read(chatMessagesProvider),
        ).deepEquals(refreshedMessages);
        final activeConversation = container.read(activeConversationProvider);
        check(activeConversation).isNotNull();
        check(activeConversation!.messages).deepEquals(refreshedMessages);
      },
    );

    test('adopts a refreshed snapshot after an obsolete stream '
        'releases its transport', () async {
      final timestamp = DateTime.now();
      final initialMessages = [
        _userMessage('user-1', 'Hello', timestamp),
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'Draft answer',
          timestamp: timestamp,
          isStreaming: true,
        ),
      ];
      final refreshedMessages = [
        _userMessage('user-1', 'Hello', timestamp),
        _assistantMessage('assistant-1', 'Final answer from web', timestamp),
      ];

      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', initialMessages, timestamp));

      check(container.read(chatMessagesProvider)).deepEquals(initialMessages);

      container.read(chatMessagesProvider.notifier).setSocketSubscriptions(
        'assistant-1',
        [() {}],
      );
      container
          .read(chatMessagesProvider.notifier)
          .retireObsoleteStreamingTransport('assistant-1');

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', refreshedMessages, timestamp));
      await pumpMicrotasks();

      check(container.read(chatMessagesProvider)).deepEquals(refreshedMessages);
    });

    test('keeps the local placeholder while the same message still owns '
        'active transport', () async {
      final timestamp = DateTime.now();
      final initialMessages = [
        _userMessage('user-1', 'Hello', timestamp),
        ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'Draft answer',
          timestamp: timestamp,
          isStreaming: true,
        ),
      ];
      final refreshedMessages = [
        _userMessage('user-1', 'Hello', timestamp),
        _assistantMessage('assistant-1', 'Final answer from web', timestamp),
      ];

      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', initialMessages, timestamp));

      container.read(chatMessagesProvider.notifier).setSocketSubscriptions(
        'assistant-1',
        [() {}],
      );

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', refreshedMessages, timestamp));
      await pumpMicrotasks();

      check(container.read(chatMessagesProvider)).deepEquals(initialMessages);
    });

    test(
      'adopts streaming server updates when rich fields change in place',
      () async {
        final timestamp = DateTime.now();
        final initialMessages = [
          _userMessage('user-1', 'Hello', timestamp),
          ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: 'Draft answer',
            timestamp: timestamp,
            isStreaming: true,
            files: const [
              {'id': 'file-1', 'status': 'pending', 'url': 'about:blank'},
            ],
            output: const [
              {'type': 'message', 'status': 'pending', 'text': 'Draft answer'},
            ],
            embeds: const [
              {'kind': 'link', 'url': 'about:blank', 'title': 'Loading'},
            ],
          ),
        ];
        final refreshedMessages = [
          _userMessage('user-1', 'Hello', timestamp),
          ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: 'Draft answer',
            timestamp: timestamp,
            isStreaming: true,
            files: const [
              {
                'id': 'file-1',
                'status': 'complete',
                'url': 'https://example.com/final.png',
              },
            ],
            output: const [
              {'type': 'message', 'status': 'complete', 'text': 'Draft answer'},
            ],
            embeds: const [
              {
                'kind': 'link',
                'url': 'https://example.com/final',
                'title': 'Ready',
              },
            ],
          ),
        ];

        final container = ProviderContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            socketServiceProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', initialMessages, timestamp));

        check(container.read(chatMessagesProvider)).deepEquals(initialMessages);

        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', refreshedMessages, timestamp));
        await pumpMicrotasks();

        check(
          container.read(chatMessagesProvider),
        ).deepEquals(refreshedMessages);
        container.read(chatMessagesProvider.notifier).clearMessages();
        container.read(activeConversationProvider.notifier).clear();
      },
    );

    test(
      'reopening a chat that is still generating re-engages streaming',
      () async {
        final timestamp = DateTime.now();
        final messages = [
          _userMessage('user-1', 'Hi', timestamp),
          _assistantMessage('assistant-1', 'Partial', timestamp),
        ];
        final api = _FakeApiService(_conversation('chat-1', messages, timestamp))
          ..taskIds = ['task-1'];

        final container = ProviderContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            socketServiceProvider.overrideWithValue(null),
            apiServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(container.dispose);

        // Build the notifier with no active conversation, then open chat-1 so
        // the conversation-change listener runs the active-on-open probe.
        check(container.read(chatMessagesProvider)).isEmpty();
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', messages, timestamp));

        check(container.read(chatMessagesProvider).last.isStreaming).isFalse();

        await pumpMicrotasks();
        await pumpMicrotasks();

        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();
      },
    );

    test('reopening a settled chat does not re-engage streaming', () async {
      final timestamp = DateTime.now();
      final messages = [
        _userMessage('user-1', 'Hi', timestamp),
        _assistantMessage('assistant-1', 'Done', timestamp),
      ];
      final api = _FakeApiService(_conversation('chat-1', messages, timestamp))
        ..taskIds = const <String>[];

      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
          apiServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);

      check(container.read(chatMessagesProvider)).isEmpty();
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', messages, timestamp));

      await pumpMicrotasks();
      await pumpMicrotasks();

      check(container.read(chatMessagesProvider).last.isStreaming).isFalse();
    });

    test('progressively adopts growing server content while resuming', () async {
      final timestamp = DateTime.now();
      final opened = [
        _userMessage('user-1', 'Hi', timestamp),
        _assistantMessage('assistant-1', 'Partial', timestamp),
      ];
      // The server has more content for the same streaming message.
      final grown = [
        _userMessage('user-1', 'Hi', timestamp),
        _assistantMessage('assistant-1', 'Partial answer that grew', timestamp),
      ];
      final api = _FakeApiService(_conversation('chat-1', grown, timestamp))
        ..taskIds = ['task-1'];

      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
          apiServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);

      check(container.read(chatMessagesProvider)).isEmpty();
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', opened, timestamp));

      // Let the active-on-open probe + the monitor's first progressive poll run.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await pumpMicrotasks();

      final last = container.read(chatMessagesProvider).last;
      check(last.content).equals('Partial answer that grew');
      check(last.isStreaming).isTrue();
    });

    test(
      'resume poll adopts server content matched by the bound foreign '
      'message id (socket bound a server id then died)',
      () async {
        final timestamp = DateTime.now();
        final opened = [
          _userMessage('user-1', 'Hi', timestamp),
          _assistantMessage('assistant-local', 'Partial', timestamp),
        ];
        // The server persists the message under its OWN (foreign) id, not the
        // local placeholder id.
        final grown = [
          _userMessage('user-1', 'Hi', timestamp),
          _assistantMessage('server-foreign', 'Partial answer that grew', timestamp),
        ];
        final api = _FakeApiService(_conversation('chat-1', grown, timestamp))
          ..taskIds = ['task-1'];

        final container = ProviderContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            socketServiceProvider.overrideWithValue(null),
            apiServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(container.dispose);

        // Construct the notifier (so its conversation-change listener is live)
        // before setting the conversation, so active-on-open fires.
        check(container.read(chatMessagesProvider)).isEmpty();
        final notifier = container.read(chatMessagesProvider.notifier);
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', opened, timestamp));

        // Active-on-open re-engages streaming and arms the monitor. The first
        // poll cannot match yet (server id differs, no bound id), so content
        // stays 'Partial'.
        await pumpMicrotasks();
        await pumpMicrotasks();
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();
        check(container.read(chatMessagesProvider).last.content).equals('Partial');

        notifier.debugCancelRemoteTaskMonitorTimer();
        while (notifier.debugTaskStatusCheckInFlight) {
          await pumpMicrotasks();
        }

        // The streaming helper binds the foreign server id to the local tail.
        notifier.recordResumeBoundRemoteMessageId(
          'assistant-local',
          'server-foreign',
        );

        // Next poll resolves the server message by the bound foreign id and
        // adopts its grown content (instead of leaving the chat stuck).
        await notifier.debugSyncRemoteTaskStatus();
        await pumpMicrotasks();

        check(
          container.read(chatMessagesProvider).last.content,
        ).equals('Partial answer that grew');
      },
    );

    test('temporary chats are never probed for active tasks', () async {
      final timestamp = DateTime.now();
      final messages = [
        _userMessage('user-1', 'Hi', timestamp),
        _assistantMessage('assistant-1', 'Partial', timestamp),
      ];
      final api = _FakeApiService(_conversation('local:tmp', messages, timestamp))
        ..taskIds = ['task-1'];

      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
          apiServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);

      check(container.read(chatMessagesProvider)).isEmpty();
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('local:tmp', messages, timestamp));

      await pumpMicrotasks();
      await pumpMicrotasks();

      // Even though the (would-be) task probe reports active, a temporary chat
      // is skipped, so the message stays settled.
      check(container.read(chatMessagesProvider).last.isStreaming).isFalse();
    });

    test(
      'tasksDone poll defers force-adoption while a socket resume stream '
      'still owns the chat, then finalizes once the grace window elapses',
      () async {
        // Feature C double-finalize race guard: when a socket resume stream
        // protects this chat, the poll must let the socket's own `done` win for
        // `_tasksDoneSocketGracePolls` iterations (no getConversation
        // force-adopt). Once the window elapses, the poll resumes as the
        // authoritative recovery finalizer and may force-adopt.
        final timestamp = DateTime.now();
        final messages = [
          _userMessage('user-1', 'Hi', timestamp),
          // Settled last message so the active-on-open probe runs (instead of
          // immediately arming the monitor on an already-streaming message).
          _assistantMessage('assistant-1', 'Partial', timestamp),
        ];
        // Server reports the finished answer (what the poll would force-adopt).
        final finished = [
          _userMessage('user-1', 'Hi', timestamp),
          _assistantMessage('assistant-1', 'Final answer', timestamp),
        ];
        final api =
            _FakeApiService(_conversation('chat-1', finished, timestamp))
              // Start with an active task so the open probe observes it.
              ..taskIds = ['task-1'];

        final container = ProviderContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            socketServiceProvider.overrideWithValue(null),
            apiServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(container.dispose);

        check(container.read(chatMessagesProvider)).isEmpty();
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-1', messages, timestamp));

        final notifier = container.read(chatMessagesProvider.notifier);

        // Let the active-on-open probe re-engage streaming + observe the task
        // and arm the 1s monitor. getConversation is not used by that path.
        await pumpMicrotasks();
        await pumpMicrotasks();
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();

        // Cancel the periodic timer so only our manual poll iterations drive the
        // grace logic (no background poll racing the deterministic assertions),
        // then drain any in-flight background poll so the re-entry guard cannot
        // short-circuit our first manual poll.
        notifier.debugCancelRemoteTaskMonitorTimer();
        while (notifier.debugTaskStatusCheckInFlight) {
          await pumpMicrotasks();
        }

        // Establish a socket resume stream protecting the last message so
        // _shouldProtectLocalStreamingState holds (Feature C resume state).
        notifier.setSocketSubscriptions('assistant-1', [() {}]);
        check(notifier.debugShouldProtectLocalStreamingState).isTrue();

        // Reset the call counter so it cleanly measures only the force-adoption
        // getConversation calls from the manual poll iterations below (the
        // open-probe's progressive-resume fetch is unrelated to this guard).
        api.getConversationCalls = 0;

        // A baseline poll while the task is still active keeps protection +
        // observed-task state intact without finalizing (tasksDone is false).
        await notifier.debugSyncRemoteTaskStatus();
        check(notifier.debugShouldProtectLocalStreamingState).isTrue();
        check(notifier.debugTasksDoneGracePolls).equals(0);
        check(api.getConversationCalls).equals(0);

        // Task disappears: every subsequent poll now sees tasksDone. The grace
        // window must suppress force-adoption for _tasksDoneSocketGracePolls (2).
        api.taskIds = const <String>[];
        check(notifier.debugShouldProtectLocalStreamingState).isTrue();

        await notifier.debugSyncRemoteTaskStatus();
        check(notifier.debugTasksDoneGracePolls).equals(1);
        check(api.getConversationCalls).equals(0);

        await notifier.debugSyncRemoteTaskStatus();
        check(notifier.debugTasksDoneGracePolls).equals(2);
        check(api.getConversationCalls).equals(0);

        // Window elapsed (counter would advance past _tasksDoneSocketGracePolls):
        // the poll resumes as the authoritative finalizer and force-adopts the
        // server state. The finalize tears down the monitor, which resets the
        // grace counter, so the observable post-finalize signal is the single
        // getConversation force-adopt + the settled, adopted message.
        await notifier.debugSyncRemoteTaskStatus();
        check(api.getConversationCalls).equals(1);
        check(container.read(chatMessagesProvider).last.content)
            .equals('Final answer');
        check(container.read(chatMessagesProvider).last.isStreaming).isFalse();
      },
    );

    test('finishStreaming releases stale socket subscriptions', () async {
      final timestamp = DateTime.now();
      final user = _userMessage('user-1', 'Hello', timestamp);
      final assistant = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Streaming answer',
        timestamp: timestamp,
        isStreaming: true,
      );

      final container = ProviderContainer(
        overrides: [
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('chat-1', [user, assistant], timestamp));

      final notifier = container.read(chatMessagesProvider.notifier);
      var disposed = false;
      notifier.setSocketSubscriptions('assistant-1', [() => disposed = true]);
      notifier.finishStreaming();

      check(disposed).isTrue();
    });

    test(
      'finishStreaming keeps folder conversation summaries untrusted until the server confirms them',
      () async {
        final timestamp = DateTime.now();
        final user = _userMessage('user-1', 'Hello', timestamp);
        final assistant = ChatMessage(
          id: 'assistant-1',
          role: 'assistant',
          content: 'Streaming answer',
          timestamp: timestamp,
          isStreaming: true,
        );

        final container = ProviderContainer(
          overrides: [
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            conversationsProvider.overrideWith(_RecordingConversations.new),
            socketServiceProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);

        container
            .read(activeConversationProvider.notifier)
            .set(
              Conversation(
                id: 'chat-1',
                title: 'Folder Chat',
                createdAt: timestamp,
                updatedAt: timestamp,
                folderId: 'folder-1',
                messages: [user, assistant],
              ),
            );

        container.read(chatMessagesProvider.notifier).finishStreaming();
        await pumpMicrotasks();

        final recorder =
            container.read(conversationsProvider.notifier)
                as _RecordingConversations;

        check(recorder.lastTrustFolderConversation).equals(false);
        check(recorder.lastUpsertedConversation).isNotNull();
        check(recorder.lastUpsertedConversation!.folderId).equals('folder-1');
      },
    );
  });
}
