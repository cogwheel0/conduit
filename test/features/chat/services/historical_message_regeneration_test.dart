import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/chat_completion_transport.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/services/historical_message_regeneration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedConversationNotifier extends ActiveConversationNotifier {
  _FixedConversationNotifier(this._conversation);

  final Conversation _conversation;

  @override
  Conversation? build() => _conversation;
}

class _NullConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _TestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];

  @override
  void addMessage(ChatMessage message) {
    state = [...state, message];
  }

  @override
  void clearMessages() {
    state = [];
  }

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }

  @override
  void updateLastMessageWithFunction(
    ChatMessage Function(ChatMessage) updater,
  ) {
    if (state.isEmpty) {
      return;
    }

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') {
      return;
    }

    final updated = updater(lastMessage);
    state = [...state.sublist(0, state.length - 1), updated];
  }

  @override
  void cancelActiveMessageStream() {}

  @override
  void finishStreaming() {
    if (state.isEmpty) {
      return;
    }

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant' || !lastMessage.isStreaming) {
      return;
    }

    state = [
      ...state.sublist(0, state.length - 1),
      lastMessage.copyWith(isStreaming: false),
    ];
  }
}

ProviderContainer _container({
  required List<ChatMessage> initialMessages,
  bool initialImageGenerationEnabled = false,
  Conversation? activeConversation,
  ApiService? apiService,
}) {
  final container = ProviderContainer(
    overrides: [
      chatMessagesProvider.overrideWith(() => _TestMessagesNotifier()),
      activeConversationProvider.overrideWith(
        () => activeConversation == null
            ? _NullConversationNotifier()
            : _FixedConversationNotifier(activeConversation),
      ),
      apiServiceProvider.overrideWithValue(apiService),
      selectedModelProvider.overrideWithValue(
        const Model(id: 'gpt-4', name: 'GPT-4'),
      ),
      reviewerModeProvider.overrideWithValue(false),
      socketServiceProvider.overrideWithValue(null),
    ],
  );

  container.read(chatMessagesProvider.notifier).setMessages(initialMessages);
  if (initialImageGenerationEnabled) {
    container.read(imageGenerationEnabledProvider.notifier).set(true);
  }

  return container;
}

class _RecordingCompletionApi extends ApiService {
  _RecordingCompletionApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  int completionCalls = 0;
  List<Map<String, dynamic>> lastMessages = const [];

  @override
  Future<Map<String, dynamic>> getUserSettings() async {
    return const <String, dynamic>{};
  }

  @override
  Future<void> syncConversationMessages(
    String conversationId,
    List<ChatMessage> messages, {
    String? title,
    String? model,
    String? systemPrompt,
  }) async {}

  @override
  Future<ChatCompletionSession> sendMessageSession({
    required List<Map<String, dynamic>> messages,
    required String model,
    String? conversationId,
    String? terminalId,
    List<String>? toolIds,
    List<String>? filterIds,
    List<String>? skillIds,
    bool enableWebSearch = false,
    bool enableImageGeneration = false,
    bool enableCodeInterpreter = false,
    bool isVoiceMode = false,
    Map<String, dynamic>? modelItem,
    String? sessionIdOverride,
    List<Map<String, dynamic>>? toolServers,
    Map<String, dynamic>? backgroundTasks,
    String? responseMessageId,
    Map<String, dynamic>? userSettings,
    String? parentId,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
  }) async {
    completionCalls += 1;
    lastMessages = messages
        .map((message) => Map<String, dynamic>.from(message))
        .toList(growable: false);

    return ChatCompletionSession.jsonCompletion(
      messageId: responseMessageId ?? 'assistant-regen',
      conversationId: conversationId,
      jsonPayload: const {
        'choices': [
          {
            'message': {'content': 'Regenerated answer'},
          },
        ],
      },
    );
  }
}

ChatMessage _userMessage({required String id, required String content}) {
  return ChatMessage(
    id: id,
    role: 'user',
    content: content,
    timestamp: DateTime.utc(2026, 4, 24),
  );
}

ChatMessage _assistantMessage({
  required String id,
  required String content,
  bool isStreaming = false,
  List<Map<String, dynamic>>? files,
  List<ChatMessageVersion> versions = const [],
}) {
  return ChatMessage(
    id: id,
    role: 'assistant',
    content: content,
    timestamp: DateTime.utc(2026, 4, 24, 0, 0, 1),
    isStreaming: isStreaming,
    files: files,
    versions: versions,
  );
}

Conversation _conversation({
  required String id,
  required List<ChatMessage> messages,
}) {
  final now = DateTime.utc(2026, 4, 24);
  return Conversation(
    id: id,
    title: 'Chat',
    createdAt: now,
    updatedAt: now,
    messages: messages,
  );
}

Future<void> _flushAsyncWork() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('regenerateHistoricalMessageById', () {
    test(
      'does nothing while another assistant response is streaming',
      () async {
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
          _userMessage(id: 'u2', content: 'Second prompt'),
          _assistantMessage(
            id: 'a2',
            content: 'Streaming answer',
            isStreaming: true,
          ),
        ];
        final container = _container(initialMessages: initialMessages);
        addTearDown(container.dispose);

        await regenerateHistoricalMessageById(container, 'a1');

        check(container.read(chatMessagesProvider)).deepEquals(initialMessages);
      },
    );

    test('restores the original branch when replay setup fails', () async {
      final initialMessages = [
        _userMessage(id: 'u1', content: 'First prompt'),
        _assistantMessage(id: 'a1', content: 'First answer'),
        _userMessage(id: 'u2', content: 'Second prompt'),
        _assistantMessage(id: 'a2', content: 'Second answer'),
      ];
      final container = _container(initialMessages: initialMessages);
      addTearDown(container.dispose);

      Object? caught;
      try {
        await regenerateHistoricalMessageById(container, 'a1');
      } catch (error) {
        caught = error;
      }

      check(caught).isNotNull();
      check(container.read(chatMessagesProvider)).deepEquals(initialMessages);
    });

    test(
      'restores image toggle and original messages after image replay fails',
      () async {
        final initialMessages = [
          _userMessage(id: 'u1', content: 'Draw a cat'),
          _assistantMessage(
            id: 'a1',
            content: '',
            files: const [
              {'type': 'image', 'url': 'https://example.com/cat.png'},
            ],
          ),
          _userMessage(id: 'u2', content: 'Second prompt'),
          _assistantMessage(id: 'a2', content: 'Second answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          initialImageGenerationEnabled: false,
        );
        addTearDown(container.dispose);

        Object? caught;
        try {
          await regenerateHistoricalMessageById(container, 'a1');
        } catch (error) {
          caught = error;
        }

        check(caught).isNotNull();
        check(container.read(imageGenerationEnabledProvider)).isFalse();
        check(container.read(chatMessagesProvider)).deepEquals(initialMessages);
      },
    );

    test(
      'temporary replay excludes archived assistants from the outbound request',
      () async {
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final api = _RecordingCompletionApi();
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'local:conv-1',
            messages: initialMessages,
          ),
          apiService: api,
        );
        addTearDown(container.dispose);

        await regenerateHistoricalMessageById(container, 'a1');
        await _flushAsyncWork();

        check(api.completionCalls).equals(1);
        check(
          api.lastMessages.map((message) => message['role']).toList(),
        ).deepEquals(['user']);
        check(api.lastMessages.single['content']).equals('First prompt');
      },
    );

    test(
      'repeated successful replay preserves the full assistant version chain',
      () async {
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final api = _RecordingCompletionApi();
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-1',
            messages: initialMessages,
          ),
          apiService: api,
        );
        addTearDown(container.dispose);

        await regenerateHistoricalMessageById(container, 'a1');
        await _flushAsyncWork();

        var messages = container.read(chatMessagesProvider);
        final firstReplay = messages.last;
        check(
          firstReplay.versions.map((version) => version.id).toList(),
        ).deepEquals(['a1']);

        await regenerateHistoricalMessageById(container, firstReplay.id);
        await _flushAsyncWork();

        messages = container.read(chatMessagesProvider);
        final secondReplay = messages.last;
        check(secondReplay.content).equals('Regenerated answer');
        check(
          secondReplay.versions.map((version) => version.id).toList(),
        ).deepEquals(['a1', firstReplay.id]);
        check(
          secondReplay.versions.map((version) => version.content).toList(),
        ).deepEquals(['First answer', 'Regenerated answer']);
      },
    );
  });
}
