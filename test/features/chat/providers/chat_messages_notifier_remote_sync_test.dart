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

  @override
  Future<Conversation> getConversation(String id) async => _conversation;
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
  });
}
