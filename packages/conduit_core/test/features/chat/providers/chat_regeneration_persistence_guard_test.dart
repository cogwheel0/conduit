import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/personal_tool_execution.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

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
  Map<String, dynamic> settings = const <String, dynamic>{};
  List<Map<String, dynamic>> lastMessages = const [];
  List<Map<String, dynamic>> lastFiles = const [];
  String? lastConversationId;
  Map<String, dynamic>? lastChatParams;
  String? lastReasoningEffort;

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async {
    return settings;
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
    Map<String, dynamic>? globalParams,
    Map<String, dynamic>? chatParams,
    String? parentId,
    String? reasoningEffort,
    Map<String, dynamic>? userMessage,
    Map<String, dynamic>? variables,
    List<Map<String, dynamic>>? files,
    List<ChatCompletionTarget>? messageIds,
  }) async {
    completionCalls += 1;
    lastConversationId = conversationId;
    lastChatParams = chatParams == null
        ? null
        : Map<String, dynamic>.of(chatParams);
    lastReasoningEffort = reasoningEffort;
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
  test('regenerate on persisted chat does not sync partial local history back to the server', () async {
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
  });

  test(
    'regenerate sends the chat\'s own saved settings and system prompt',
    () async {
      final now = DateTime.utc(2026, 4, 23, 12);
      final conversation = Conversation(
        id: 'conv-params',
        title: 'Configured chat',
        createdAt: now,
        updatedAt: now,
        chatParams: const {
          'system': 'Answer in French.',
          'temperature': 0.1,
          'reasoning_effort': 'low',
        },
        messages: [
          ChatMessage(
            id: 'user-1',
            role: 'user',
            content: 'Explain this bug.',
            timestamp: now,
          ),
          ChatMessage(
            id: 'assistant-1',
            role: 'assistant',
            content: 'Original answer',
            timestamp: now.add(const Duration(seconds: 1)),
            model: 'gpt-4',
          ),
        ],
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
      container
          .read(chatMessagesProvider.notifier)
          .setMessages(conversation.messages);

      await container.read(regenerateLastMessageProvider)();
      await Future<void>.delayed(Duration.zero);

      check(api.completionCalls).equals(1);
      check(api.lastChatParams).isNotNull().deepEquals({
        'system': 'Answer in French.',
        'temperature': 0.1,
        'reasoning_effort': 'low',
      });
      check(api.lastMessages).deepEquals([
        {'role': 'system', 'content': 'Answer in French.'},
      ]);
    },
  );

  test('a regeneration admits the personal server it sent, for its chat and message', () async {
    final now = DateTime.utc(2026, 4, 23, 12);
    final host = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => host.close(force: true));
    host.listen((request) {
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'openapi': '3.0.0',
            'info': <String, dynamic>{'title': 'Notes', 'version': '1'},
            'paths': <String, dynamic>{
              '/notes': <String, dynamic>{
                'post': <String, dynamic>{'operationId': 'createNote'},
              },
            },
          }),
        );
      request.response.close();
    });
    final entry = <String, dynamic>{
      'type': 'openapi',
      'url': 'http://127.0.0.1:${host.port}',
      'spec_type': 'url',
      'path': '/openapi.json',
      'auth_type': 'none',
      'config': <String, dynamic>{'enable': true},
      'info': <String, dynamic>{'id': 'notes', 'name': 'Notes'},
    };
    final userMessage = ChatMessage(
      id: 'user-1',
      role: 'user',
      content: 'Write it down.',
      timestamp: now,
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
      title: 'Notes chat',
      createdAt: now,
      updatedAt: now,
      messages: [userMessage, assistantMessage],
    );
    final api = _RecordingCompletionApi()
      ..settings = <String, dynamic>{
        'ui': <String, dynamic>{
          'toolServers': <dynamic>[
            entry,
            <String, dynamic>{
              ...entry,
              'url': 'http://127.0.0.1:1',
              'info': <String, dynamic>{'id': 'unselected', 'name': 'Other'},
            },
          ],
        },
      };
    final socket = _AdmissionSocketService();
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
        socketServiceProvider.overrideWithValue(socket),
      ],
    );
    addTearDown(container.dispose);
    container.read(chatMessagesProvider.notifier).setMessages([
      userMessage,
      assistantMessage,
    ]);
    container.read(selectedToolIdsProvider.notifier).set(<String>[
      'direct_server:notes',
    ]);

    await container.read(regenerateLastMessageProvider)();
    await Future<void>.delayed(Duration.zero);

    check(api.completionCalls).equals(1);
    final admission = socket.admissions.single;
    check(admission.chatId).equals('conv-1');
    check(admission.sessionId).equals('regen-socket');
    check(admission.messageId).isNotEmpty();
    final connection = admission.connections.single;
    check(connection.kind).equals(PersonalConnectionKind.toolServer);
    check(connection.identity).equals('notes');
    check(connection.url).equals('http://127.0.0.1:${host.port}');
    check(connection.operations).deepEquals(<String>{'createNote'});
  });
}

typedef _RecordedAdmission = ({
  String? chatId,
  String messageId,
  String? sessionId,
  List<PersonalToolAdmission> connections,
});

/// A connected socket that records what each chat request admitted.
class _AdmissionSocketService extends SocketService {
  _AdmissionSocketService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
      );

  final List<_RecordedAdmission> admissions = <_RecordedAdmission>[];

  @override
  bool get isConnected => true;

  @override
  String? get sessionId => 'regen-socket';

  @override
  void admitPersonalToolServers({
    required String? chatId,
    required String messageId,
    required String? sessionId,
    required Iterable<PersonalToolAdmission> connections,
  }) {
    admissions.add((
      chatId: chatId,
      messageId: messageId,
      sessionId: sessionId,
      connections: List<PersonalToolAdmission>.of(connections),
    ));
  }
}
