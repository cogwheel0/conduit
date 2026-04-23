import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/chat_completion_transport.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedConversationNotifier extends ActiveConversationNotifier {
  _FixedConversationNotifier(this._conversation);

  final Conversation _conversation;

  @override
  Conversation? build() => _conversation;
}

class _TestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];

  @override
  void addMessage(ChatMessage message) {
    state = [...state, message];
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

    final updated = updater(state.last);
    state = [...state.sublist(0, state.length - 1), updated];
  }

  @override
  void replaceLastMessageContent(String content) {
    if (state.isEmpty) {
      return;
    }

    final last = state.last;
    state = [
      ...state.sublist(0, state.length - 1),
      last.copyWith(content: content),
    ];
  }

  @override
  void finishStreaming() {
    if (state.isEmpty) {
      return;
    }

    final last = state.last;
    state = [
      ...state.sublist(0, state.length - 1),
      last.copyWith(isStreaming: false),
    ];
  }
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

  int syncCalls = 0;
  int completionCalls = 0;
  List<Map<String, dynamic>> lastMessages = const [];
  List<Map<String, dynamic>> lastFiles = const [];
  String? lastConversationId;

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
  }) async {
    syncCalls += 1;
  }

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
    lastConversationId = conversationId;
    lastMessages = messages
        .map((message) => Map<String, dynamic>.from(message))
        .toList(growable: false);
    lastFiles =
        files
            ?.map((file) => Map<String, dynamic>.from(file))
            .toList(growable: false) ??
        const [];

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'regenerate on persisted chat does not sync partial local history back to the server',
    () async {
      final now = DateTime.utc(2026, 4, 23, 12);
      final userMessage = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Explain this bug.',
        timestamp: now,
        files: const [
          {
            'type': 'file',
            'id': 'doc-1',
            'url': 'doc-1',
            'name': 'bug-report.md',
            'content_type': 'text/markdown',
          },
        ],
      );
      final assistantMessage = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: 'Original answer',
        timestamp: now.add(const Duration(seconds: 1)),
        model: 'gpt-4',
      );
      final conversation = Conversation(
        id: 'conv-1',
        title: 'Long chat',
        createdAt: now,
        updatedAt: now,
        messages: [userMessage, assistantMessage],
      );
      final api = _RecordingCompletionApi();
      final container = ProviderContainer(
        overrides: [
          chatMessagesProvider.overrideWith(() => _TestMessagesNotifier()),
          activeConversationProvider.overrideWith(
            () => _FixedConversationNotifier(conversation),
          ),
          apiServiceProvider.overrideWithValue(api),
          selectedModelProvider.overrideWithValue(
            const Model(id: 'gpt-4', name: 'GPT-4'),
          ),
          reviewerModeProvider.overrideWithValue(false),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      container.read(chatMessagesProvider.notifier).setMessages([
        userMessage,
        assistantMessage,
      ]);

      await container.read(regenerateLastMessageProvider)();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      check(api.completionCalls).equals(1);
      check(api.syncCalls).equals(0);
      check(api.lastConversationId).equals('conv-1');
      check(api.lastMessages).isEmpty();
      check(api.lastFiles).deepEquals(const [
        {
          'type': 'file',
          'id': 'doc-1',
          'url': 'doc-1',
          'name': 'bug-report.md',
          'content_type': 'text/markdown',
        },
      ]);

      final messages = container.read(chatMessagesProvider);
      check(messages).has((it) => it.length, 'length').equals(3);
      check(messages.last.role).equals('assistant');
      check(messages.last.content).equals('Regenerated answer');
      check(messages.last.isStreaming).isFalse();
    },
  );
}
