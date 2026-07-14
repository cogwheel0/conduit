import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/database/local_conversation_loader.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/chat_completion_transport.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/core/sync/outbox_drainer.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit/features/chat/services/request_completion_runner.dart';
import 'package:conduit/features/chat/services/chat_transport_dispatch.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/features/tools/providers/tools_providers.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this.initial);

  final Conversation initial;

  @override
  Conversation? build() => initial;
}

class _TestMessagesNotifier extends ChatMessagesNotifier {
  int socketRegistrationCalls = 0;

  @override
  List<ChatMessage> build() => const [];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = List<ChatMessage>.from(messages);
  }

  @override
  void addMessage(ChatMessage message) {
    state = <ChatMessage>[...state, message];
  }

  @override
  void addMessages(List<ChatMessage> messages) {
    state = <ChatMessage>[...state, ...messages];
  }

  @override
  void updateLastMessageWithFunction(
    ChatMessage Function(ChatMessage message) updater,
  ) {
    if (state.isEmpty) return;
    state = <ChatMessage>[
      ...state.sublist(0, state.length - 1),
      updater(state.last),
    ];
  }

  @override
  void updateMessageById(
    String messageId,
    ChatMessage Function(ChatMessage current) updater,
  ) {
    final index = state.indexWhere((message) => message.id == messageId);
    if (index < 0) return;
    final next = List<ChatMessage>.from(state);
    next[index] = updater(next[index]);
    state = next;
  }

  @override
  void appendToLastMessage(String content) {
    if (state.isEmpty) return;
    updateLastMessageWithFunction(
      (message) => message.copyWith(content: '${message.content}$content'),
    );
  }

  @override
  void bufferLastMessageContent(String content) {
    replaceLastMessageContent(content);
  }

  @override
  void replaceLastMessageContent(String content) {
    if (state.isEmpty) return;
    updateLastMessageWithFunction(
      (message) => message.copyWith(content: content),
    );
  }

  @override
  void finishStreaming() {
    if (state.isEmpty) return;
    updateLastMessageWithFunction(
      (message) => message.copyWith(isStreaming: false),
    );
  }

  @override
  void setSocketSubscriptions(
    String messageId,
    List<void Function()> subscriptions, {
    void Function()? onDispose,
  }) {
    socketRegistrationCalls++;
    super.setSocketSubscriptions(
      messageId,
      subscriptions,
      onDispose: onDispose,
    );
  }
}

class _FalseTemporaryChat extends TemporaryChatEnabled {
  @override
  bool build() => false;
}

class _FalseWebSearch extends WebSearchEnabledNotifier {
  @override
  bool build() => false;
}

class _FalseImageGeneration extends ImageGenerationEnabledNotifier {
  @override
  bool build() => false;
}

class _GatedCompletionApi extends ApiService {
  _GatedCompletionApi(this.releasePost)
    : super(
        serverConfig: const ServerConfig(
          id: 'transport-ownership',
          name: 'Transport ownership',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final Completer<void> releasePost;
  final Completer<void> postEntered = Completer<void>();
  int completionCalls = 0;
  String? assistantMessageId;

  @override
  Future<Map<String, dynamic>> getUserSettings() async => const {};

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async => const [];

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
    assistantMessageId = responseMessageId;
    if (!postEntered.isCompleted) postEntered.complete();
    await releasePost.future;
    return ChatCompletionSession.jsonCompletion(
      messageId: responseMessageId!,
      conversationId: conversationId,
      jsonPayload: const <String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': 'A safely completed'},
          },
        ],
      },
    );
  }
}

class _GatedSocketService extends SocketService {
  _GatedSocketService(this.releaseConnection)
    : super(
        serverConfig: const ServerConfig(
          id: 'gated-socket',
          name: 'Gated socket',
          url: 'https://example.com',
        ),
      );

  final Completer<void> releaseConnection;
  final Completer<void> connectionEntered = Completer<void>();

  @override
  bool get isConnected => false;

  @override
  String? get sessionId => 'socket-a';

  @override
  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (!connectionEntered.isCompleted) connectionEntered.complete();
    await releaseConnection.future;
    return true;
  }
}

class _SynchronousCompletionSocketService extends SocketService {
  _SynchronousCompletionSocketService()
    : super(
        serverConfig: const ServerConfig(
          id: 'synchronous-completion-socket',
          name: 'Synchronous completion socket',
          url: 'https://example.com',
        ),
      );

  int chatSubscriptionDisposals = 0;
  int channelRegistrationCalls = 0;

  @override
  bool get isConnected => true;

  @override
  String? get sessionId => 'socket-a';

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) {
    handler(<String, dynamic>{
      'chat_id': conversationId,
      'message_id': messageId,
      'session_id': sessionId,
      'data': <String, dynamic>{
        'type': 'chat:completion',
        'data': <String, dynamic>{'content': 'Already completed', 'done': true},
      },
    }, null);
    return SocketEventSubscription(() => chatSubscriptionDisposals++);
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) {
    channelRegistrationCalls++;
    return SocketEventSubscription(() {});
  }
}

class _CountingPassiveSocketService extends SocketService {
  _CountingPassiveSocketService()
    : super(
        serverConfig: const ServerConfig(
          id: 'transport-ownership',
          name: 'Transport ownership',
          url: 'https://example.com',
        ),
      );

  int chatRegistrationCalls = 0;
  int chatSubscriptionDisposals = 0;
  SocketChatEventHandler? chatHandler;

  @override
  bool get isConnected => true;

  @override
  String? get sessionId => 'passive-socket';

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    required SocketChatEventHandler handler,
  }) {
    chatRegistrationCalls += 1;
    chatHandler = handler;
    return SocketEventSubscription(() => chatSubscriptionDisposals += 1);
  }

  void emitChatEvent({
    required String type,
    required Map<String, dynamic> payload,
    String? chatId,
    String? messageId,
    String? sessionId,
  }) {
    chatHandler?.call(<String, dynamic>{
      'chat_id': ?chatId,
      'message_id': ?messageId,
      'session_id': ?sessionId,
      'data': <String, dynamic>{'type': type, 'data': payload},
    }, null);
  }
}

class _PersistingSyncEngine extends SyncEngine {
  _PersistingSyncEngine(
    this.db,
    this.api, {
    this.landResponse = true,
    this.throwOnPull = false,
  });

  final AppDatabase db;
  final _GatedCompletionApi api;
  final bool landResponse;
  final bool throwOnPull;
  int pulls = 0;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<Conversation?> pullChatNow(String requestedChatId) async {
    pulls += 1;
    if (throwOnPull) throw StateError('pull failed');
    if (!landResponse) return null;
    final assistantId = api.assistantMessageId!;
    final completed = ChatMessage(
      id: assistantId,
      role: 'assistant',
      content: 'A safely completed',
      timestamp: DateTime.utc(2026, 7, 13, 0, 0, 2),
      model: 'model-1',
      isStreaming: false,
      metadata: const <String, dynamic>{'responseDone': true},
    );
    await db.messagesDao.upsertLocalEcho(
      MessageRowData(
        id: assistantId,
        chatId: requestedChatId,
        role: 'assistant',
        content: completed.content,
        model: completed.model,
        createdAt: completed.timestamp.millisecondsSinceEpoch ~/ 1000,
        orderIndex: 1,
        payload: <String, dynamic>{
          ...completed.toJson(),
          'timestamp': completed.timestamp.millisecondsSinceEpoch ~/ 1000,
          'done': true,
        },
      ),
    );
    return withChatStorageProvenance(
      Conversation(
        id: requestedChatId,
        title: 'A',
        createdAt: DateTime.utc(2026, 7, 13),
        updatedAt: DateTime.utc(2026, 7, 13),
        messages: <ChatMessage>[completed],
      ),
      ChatStorageKind.openWebUi,
    );
  }
}

class _GatedNullPullSyncEngine extends SyncEngine {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<Conversation?> pullChatNow(String chatId) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return null;
  }
}

class _CountingConversationApi extends ApiService {
  _CountingConversationApi(String serverId)
    : super(
        serverConfig: ServerConfig(
          id: serverId,
          name: serverId,
          url: 'https://$serverId.example.test',
        ),
        workerManager: WorkerManager(),
      );

  int getConversationCalls = 0;

  @override
  Future<Conversation> getConversation(String id) async {
    getConversationCalls++;
    return Conversation(
      id: id,
      title: serverConfig.id,
      createdAt: DateTime.utc(2026, 7, 13),
      updatedAt: DateTime.utc(2026, 7, 13),
    );
  }
}

Conversation _conversation(
  String id,
  List<ChatMessage> messages,
  ChatStorageKind storage, {
  String? backend,
}) => withChatStorageProvenance(
  Conversation(
    id: id,
    title: storage == ChatStorageKind.openWebUi ? 'A' : 'B',
    createdAt: DateTime.utc(2026, 7, 13),
    updatedAt: DateTime.utc(2026, 7, 13),
    messages: messages,
    metadata: backend == null
        ? const <String, dynamic>{}
        : <String, dynamic>{'backend': backend},
  ),
  storage,
);

ChatMessage _user(String id, String content) => ChatMessage(
  id: id,
  role: 'user',
  content: content,
  timestamp: DateTime.utc(2026, 7, 13),
);

ChatMessage _streamingAssistant(String id, String content) => ChatMessage(
  id: id,
  role: 'assistant',
  content: content,
  timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
  model: 'model-1',
  isStreaming: true,
  metadata: const <String, dynamic>{'owner': 'B'},
);

String _snapshot(List<ChatMessage> messages) => jsonEncode(
  messages.map((message) => message.toJson()).toList(growable: false),
);

Future<void> _seedChat(
  AppDatabase db,
  String chatId, {
  String? assistantId,
  String assistantContent = '',
}) async {
  await db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: chatId,
          title: 'A',
          createdAt: 1,
          updatedAt: 1,
          bodySynced: const Value(true),
        ),
      );
  if (assistantId == null) return;
  await db
      .into(db.messages)
      .insert(
        MessagesCompanion.insert(
          id: assistantId,
          chatId: chatId,
          role: 'assistant',
          content: assistantContent,
          model: const Value('model-1'),
          createdAt: 1,
          orderIndex: 1,
          payload: jsonEncode(<String, dynamic>{
            'id': assistantId,
            'role': 'assistant',
            'content': assistantContent,
            'model': 'model-1',
            'timestamp': 1,
            'isStreaming': true,
          }),
        ),
      );
}

ProviderContainer _container({
  required AppDatabase db,
  required Conversation active,
  required List<ChatMessage> messages,
  required _GatedCompletionApi api,
  required _PersistingSyncEngine syncEngine,
}) {
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => db),
      activeConversationProvider.overrideWith(() => _SeededActive(active)),
      chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      apiServiceProvider.overrideWithValue(api),
      selectedModelProvider.overrideWithValue(
        const Model(id: 'model-1', name: 'Model 1'),
      ),
      reviewerModeProvider.overrideWithValue(false),
      socketServiceProvider.overrideWithValue(null),
      temporaryChatEnabledProvider.overrideWith(_FalseTemporaryChat.new),
      webSearchEnabledProvider.overrideWith(_FalseWebSearch.new),
      imageGenerationEnabledProvider.overrideWith(_FalseImageGeneration.new),
      webSearchAvailableProvider.overrideWithValue(false),
      imageGenerationAvailableProvider.overrideWithValue(false),
      selectedFilterIdsProvider.overrideWithValue(const <String>[]),
      selectedTerminalIdProvider.overrideWithValue(null),
      syncEngineProvider.overrideWith(() => syncEngine),
    ],
  );
  container.read(chatMessagesProvider.notifier).setMessages(messages);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test(
    'inline POST navigation continues A headlessly without touching colliding B',
    () async {
      const chatId = 'same-chat-id';
      await _seedChat(db, chatId);
      final releasePost = Completer<void>();
      final api = _GatedCompletionApi(releasePost);
      final syncEngine = _PersistingSyncEngine(db, api);
      final aMessages = <ChatMessage>[_user('a-user-existing', 'A history')];
      final container = _container(
        db: db,
        active: _conversation(chatId, aMessages, ChatStorageKind.openWebUi),
        messages: aMessages,
        api: api,
        syncEngine: syncEngine,
      );
      addTearDown(container.dispose);

      final send = sendMessageWithContainer(container, 'A new turn', null);
      await api.postEntered.future;
      final assistantId = api.assistantMessageId!;
      final bMessages = <ChatMessage>[
        _user('b-user', 'B exact bytes'),
        _streamingAssistant(assistantId, 'B is still streaming'),
      ];
      final bSnapshot = _snapshot(bMessages);
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation(chatId, bMessages, ChatStorageKind.directLocal));
      container.read(chatMessagesProvider.notifier).setMessages(bMessages);
      container
          .read(contextAttachmentsProvider.notifier)
          .addNote(noteId: 'b-note', displayName: 'B note');

      releasePost.complete();
      await send;
      await Future<void>.delayed(Duration.zero);

      check(api.completionCalls).equals(1);
      check(syncEngine.pulls).equals(1);
      check(_snapshot(container.read(chatMessagesProvider))).equals(bSnapshot);
      check(container.read(chatMessagesProvider).last.isStreaming).isTrue();
      check(
        container.read(contextAttachmentsProvider).single.id,
      ).equals('b-note');
      final persisted = await db.messagesDao.getMessage(chatId, assistantId);
      check(persisted).isNotNull();
      check(persisted!.content).equals('A safely completed');
    },
  );

  test(
    'queued POST navigation continues A headlessly without touching colliding B',
    () async {
      const chatId = 'same-queued-chat-id';
      const assistantId = 'same-assistant-id';
      await _seedChat(db, chatId, assistantId: assistantId);
      final releasePost = Completer<void>();
      final api = _GatedCompletionApi(releasePost);
      final syncEngine = _PersistingSyncEngine(db, api);
      final aMessages = <ChatMessage>[
        _user('a-user', 'A queued turn'),
        ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
          model: 'model-1',
          isStreaming: true,
        ),
      ];
      final container = _container(
        db: db,
        active: _conversation(chatId, aMessages, ChatStorageKind.openWebUi),
        messages: aMessages,
        api: api,
        syncEngine: syncEngine,
      );
      addTearDown(container.dispose);

      final completion = runQueuedCompletion(
        container,
        chatId: chatId,
        assistantMessageId: assistantId,
        model: 'model-1',
      );
      await api.postEntered.future;
      final pendingRow = await db.messagesDao.getMessage(chatId, assistantId);
      final pendingPayload =
          jsonDecode(pendingRow!.payload) as Map<String, dynamic>;
      final pendingMetadata =
          pendingPayload['metadata'] as Map<String, dynamic>? ?? const {};
      check(pendingMetadata['completionSubmitted']).isNull();
      final bMessages = <ChatMessage>[
        _user('b-user', 'B exact bytes'),
        _streamingAssistant(assistantId, 'B is still streaming'),
      ];
      final bSnapshot = _snapshot(bMessages);
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation(chatId, bMessages, ChatStorageKind.directLocal));
      container.read(chatMessagesProvider.notifier).setMessages(bMessages);

      releasePost.complete();
      await completion;
      await Future<void>.delayed(Duration.zero);

      check(api.completionCalls).equals(1);
      check(syncEngine.pulls).equals(1);
      check(_snapshot(container.read(chatMessagesProvider))).equals(bSnapshot);
      check(container.read(chatMessagesProvider).last.isStreaming).isTrue();
      final persisted = await db.messagesDao.getMessage(chatId, assistantId);
      check(persisted).isNotNull();
      check(persisted!.content).equals('A safely completed');
    },
  );

  test(
    'equal OpenWebUI ids on two servers never pull or mutate server B',
    () async {
      const chatId = 'same-server-chat-id';
      const assistantId = 'same-server-assistant-id';
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      await _seedChat(db, chatId, assistantId: assistantId);
      await _seedChat(
        dbB,
        chatId,
        assistantId: assistantId,
        assistantContent: 'B database bytes',
      );

      final releasePost = Completer<void>();
      final apiA = _GatedCompletionApi(releasePost);
      final releaseB = Completer<void>()..complete();
      final apiB = _GatedCompletionApi(releaseB);
      final syncEngineA = _PersistingSyncEngine(db, apiA);
      final aMessages = <ChatMessage>[
        _user('a-user', 'A queued turn'),
        ChatMessage(
          id: assistantId,
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
          model: 'model-1',
          isStreaming: true,
        ),
      ];
      final container = _container(
        db: db,
        active: _conversation(chatId, aMessages, ChatStorageKind.openWebUi),
        messages: aMessages,
        api: apiA,
        syncEngine: syncEngineA,
      );
      addTearDown(container.dispose);

      final completion = runQueuedCompletion(
        container,
        chatId: chatId,
        assistantMessageId: assistantId,
        model: 'model-1',
      );
      await apiA.postEntered.future;

      final bMessages = <ChatMessage>[
        _user('b-user', 'B exact bytes'),
        _streamingAssistant(assistantId, 'B is still streaming'),
      ];
      container.updateOverrides([
        appDatabaseProvider.overrideWith((ref) => dbB),
        activeConversationProvider.overrideWith(
          () => _SeededActive(
            _conversation(chatId, bMessages, ChatStorageKind.openWebUi),
          ),
        ),
        chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
        apiServiceProvider.overrideWithValue(apiB),
        selectedModelProvider.overrideWithValue(
          const Model(id: 'model-1', name: 'Model 1'),
        ),
        reviewerModeProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(null),
        temporaryChatEnabledProvider.overrideWith(_FalseTemporaryChat.new),
        webSearchEnabledProvider.overrideWith(_FalseWebSearch.new),
        imageGenerationEnabledProvider.overrideWith(_FalseImageGeneration.new),
        webSearchAvailableProvider.overrideWithValue(false),
        imageGenerationAvailableProvider.overrideWithValue(false),
        selectedFilterIdsProvider.overrideWithValue(const <String>[]),
        selectedTerminalIdProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(() => syncEngineA),
      ]);
      final bSnapshot = _snapshot(bMessages);
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation(chatId, bMessages, ChatStorageKind.openWebUi));
      container.read(chatMessagesProvider.notifier).setMessages(bMessages);

      releasePost.complete();
      await completion;
      await Future<void>.delayed(Duration.zero);

      check(apiA.completionCalls).equals(1);
      check(apiB.completionCalls).equals(0);
      check(syncEngineA.pulls).equals(0);
      check(_snapshot(container.read(chatMessagesProvider))).equals(bSnapshot);
      final persistedB = await dbB.messagesDao.getMessage(chatId, assistantId);
      check(persistedB).isNotNull();
      check(persistedB!.content).equals('B database bytes');
      final persistedA = await db.messagesDao.getMessage(chatId, assistantId);
      check(persistedA).isNotNull();
      final payloadA = jsonDecode(persistedA!.payload) as Map<String, dynamic>;
      final metadataA = payloadA['metadata'] as Map<String, dynamic>;
      check(metadataA['completionSubmitted'] as bool).isTrue();
      check(metadataA['responseDone']).isNull();
    },
  );

  test('accepted-submission marker fails when the row is absent', () async {
    const chatId = 'missing-marker-chat';
    await _seedChat(db, chatId);
    final release = Completer<void>()..complete();
    final api = _GatedCompletionApi(release);
    final syncEngine = _PersistingSyncEngine(db, api, landResponse: false);
    final messages = <ChatMessage>[_user('user', 'hello')];
    final container = _container(
      db: db,
      active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
      messages: messages,
      api: api,
      syncEngine: syncEngine,
    );
    addTearDown(container.dispose);
    final owner = captureOpenWebUiCompletionOwner(
      container,
      chatId: chatId,
      database: db,
      api: api,
    );

    await check(
      beginOpenWebUiCompletionSubmission(
        container,
        owner: owner,
        assistantMessageId: 'absent-assistant',
      ),
    ).throws<SyncTerminalException>();
    check(api.completionCalls).equals(0);
  });

  test(
    'a recreated runner treats an accepted marker as pull-only recovery',
    () async {
      const chatId = 'crash-window-chat';
      const assistantId = 'crash-window-assistant';
      await _seedChat(db, chatId, assistantId: assistantId);
      final release = Completer<void>()..complete();
      final api = _GatedCompletionApi(release);
      final syncEngine = _PersistingSyncEngine(db, api, landResponse: false);
      final messages = <ChatMessage>[
        _user('user', 'hello'),
        _streamingAssistant(assistantId, ''),
      ];
      final container = _container(
        db: db,
        active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
        messages: messages,
        api: api,
        syncEngine: syncEngine,
      );
      addTearDown(container.dispose);
      final owner = captureOpenWebUiCompletionOwner(
        container,
        chatId: chatId,
        database: db,
        api: api,
      );
      await beginOpenWebUiCompletionSubmission(
        container,
        owner: owner,
        assistantMessageId: assistantId,
      );

      final runnerProvider = Provider<RequestCompletionRunner>(
        (ref) => ChatRequestCompletionRunner(
          ref,
          recoveryAttempts: 1,
          recoveryDelay: Duration.zero,
        ),
      );
      final runner = container.read(runnerProvider);
      await runner.run(
        chatId: chatId,
        payload: RequestCompletionPayload(
          assistantMessageId: assistantId,
          model: 'model-1',
        ).toJson(),
      );

      check(api.completionCalls).equals(0);
      check(syncEngine.pulls).equals(1);
      final persisted = await db.messagesDao.getMessage(chatId, assistantId);
      final payload = jsonDecode(persisted!.payload) as Map<String, dynamic>;
      check(payload['done'] as bool).isTrue();
      check(payload['error']).isNotNull();
    },
  );

  test(
    'drain and pull failure settles the captured placeholder explicitly',
    () async {
      const chatId = 'drain-failure-chat';
      const assistantId = 'drain-failure-assistant';
      await _seedChat(db, chatId, assistantId: assistantId);
      final release = Completer<void>()..complete();
      final api = _GatedCompletionApi(release);
      final syncEngine = _PersistingSyncEngine(db, api, throwOnPull: true);
      final messages = <ChatMessage>[
        _user('user', 'hello'),
        _streamingAssistant(assistantId, ''),
      ];
      final container = _container(
        db: db,
        active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
        messages: messages,
        api: api,
        syncEngine: syncEngine,
      );
      addTearDown(container.dispose);
      var aborted = false;
      final session = ChatCompletionSession.httpStream(
        messageId: assistantId,
        conversationId: chatId,
        byteStream: Stream<List<int>>.error(StateError('stream failed')),
        abort: () async {
          aborted = true;
        },
      );

      await finishSubmittedOpenWebUiCompletionHeadlesslyForTest(
        container,
        session: session,
        chatId: chatId,
        assistantMessageId: assistantId,
        recoveryAttempts: 2,
        recoveryDelay: Duration.zero,
      );

      check(aborted).isTrue();
      check(syncEngine.pulls).equals(2);
      final persisted = await db.messagesDao.getMessage(chatId, assistantId);
      final payload = jsonDecode(persisted!.payload) as Map<String, dynamic>;
      check(payload['done'] as bool).isTrue();
      check(payload['error']).isNotNull();
    },
  );

  test(
    'socket bind loss returns unattached and cannot mutate the new chat',
    () async {
      final releasePost = Completer<void>()..complete();
      final api = _GatedCompletionApi(releasePost);
      final syncEngine = _PersistingSyncEngine(db, api, landResponse: false);
      final aMessages = <ChatMessage>[_streamingAssistant('assistant-a', '')];
      final container = _container(
        db: db,
        active: _conversation('chat-a', aMessages, ChatStorageKind.openWebUi),
        messages: aMessages,
        api: api,
        syncEngine: syncEngine,
      );
      addTearDown(container.dispose);
      final releaseConnection = Completer<void>();
      final socket = _GatedSocketService(releaseConnection);
      addTearDown(socket.dispose);
      var owns = true;

      final dispatch = dispatchChatTransport(
        ref: container,
        session: ChatCompletionSession.taskSocket(
          messageId: 'assistant-a',
          conversationId: 'chat-a',
          taskId: 'task-a',
        ),
        assistantMessageId: 'assistant-a',
        modelId: 'model-1',
        modelItem: const <String, dynamic>{'id': 'model-1'},
        activeConversationId: 'chat-a',
        api: api,
        socketService: socket,
        workerManager: WorkerManager(),
        webSearchEnabled: false,
        imageGenerationEnabled: false,
        isBackgroundFlow: false,
        modelUsesReasoning: false,
        toolsEnabled: false,
        isTemporary: false,
        ownsActiveConversation: () => owns,
      );
      await socket.connectionEntered.future;
      final bMessages = <ChatMessage>[
        _streamingAssistant('assistant-b', 'B exact bytes'),
      ];
      final bSnapshot = _snapshot(bMessages);
      owns = false;
      container.read(chatMessagesProvider.notifier).setMessages(bMessages);
      releaseConnection.complete();

      check(await dispatch).isFalse();
      check(_snapshot(container.read(chatMessagesProvider))).equals(bSnapshot);
    },
  );

  test(
    'chat inactive clears global activity after foreground ownership changes',
    () async {
      final releasePost = Completer<void>()..complete();
      final api = _GatedCompletionApi(releasePost);
      final syncEngine = _PersistingSyncEngine(db, api, landResponse: false);
      final messages = <ChatMessage>[_streamingAssistant('assistant-a', '')];
      final container = _container(
        db: db,
        active: _conversation('chat-a', messages, ChatStorageKind.openWebUi),
        messages: messages,
        api: api,
        syncEngine: syncEngine,
      );
      addTearDown(container.dispose);
      final socket = _CountingPassiveSocketService();
      addTearDown(socket.dispose);
      var owns = true;

      final attached = await dispatchChatTransport(
        ref: container,
        session: ChatCompletionSession.taskSocket(
          messageId: 'assistant-a',
          sessionId: 'passive-socket',
          conversationId: 'chat-a',
          taskId: 'task-a',
        ),
        assistantMessageId: 'assistant-a',
        modelId: 'model-1',
        modelItem: const <String, dynamic>{'id': 'model-1'},
        activeConversationId: 'chat-a',
        api: api,
        socketService: socket,
        workerManager: WorkerManager(),
        webSearchEnabled: false,
        imageGenerationEnabled: false,
        isBackgroundFlow: false,
        modelUsesReasoning: false,
        toolsEnabled: false,
        isTemporary: false,
        ownsActiveConversation: () => owns,
      );
      check(attached).isTrue();
      check(container.read(activeChatIdsProvider)).contains('chat-a');

      owns = false;
      socket.emitChatEvent(
        type: 'chat:active',
        payload: const <String, dynamic>{'active': false},
        chatId: 'chat-a',
        messageId: 'assistant-a',
        sessionId: 'passive-socket',
      );
      await Future<void>.delayed(Duration.zero);

      check(
        container.read(activeChatIdsProvider),
      ).not((activeIds) => activeIds.contains('chat-a'));
    },
  );

  test(
    'synchronous buffered completion is not re-registered after teardown',
    () async {
      final releasePost = Completer<void>()..complete();
      final api = _GatedCompletionApi(releasePost);
      final syncEngine = _PersistingSyncEngine(db, api, landResponse: false);
      final messages = <ChatMessage>[_streamingAssistant('assistant-a', '')];
      final container = _container(
        db: db,
        active: _conversation(
          'local:chat-a',
          messages,
          ChatStorageKind.openWebUi,
        ),
        messages: messages,
        api: api,
        syncEngine: syncEngine,
      );
      addTearDown(container.dispose);
      final socket = _SynchronousCompletionSocketService();
      addTearDown(socket.dispose);

      final attached = await dispatchChatTransport(
        ref: container,
        session: ChatCompletionSession.taskSocket(
          messageId: 'assistant-a',
          conversationId: 'local:chat-a',
          taskId: 'task-a',
        ),
        assistantMessageId: 'assistant-a',
        modelId: 'model-1',
        modelItem: const <String, dynamic>{'id': 'model-1'},
        activeConversationId: 'local:chat-a',
        api: api,
        socketService: socket,
        workerManager: WorkerManager(),
        webSearchEnabled: false,
        imageGenerationEnabled: false,
        isBackgroundFlow: false,
        modelUsesReasoning: false,
        toolsEnabled: false,
        isTemporary: true,
      );

      final notifier =
          container.read(chatMessagesProvider.notifier)
              as _TestMessagesNotifier;
      check(attached).isTrue();
      check(
        container.read(chatMessagesProvider).single.content,
      ).equals('Already completed');
      check(container.read(chatMessagesProvider).single.isStreaming).isFalse();
      check(socket.chatSubscriptionDisposals).equals(1);
      check(socket.channelRegistrationCalls).equals(0);
      check(notifier.socketRegistrationCalls).equals(0);
    },
  );

  test(
    'stale OpenWebUI remap is rejected after the selected server changes',
    () async {
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final apiA = _GatedCompletionApi(Completer<void>()..complete());
      final apiB = _GatedCompletionApi(Completer<void>()..complete());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(apiA),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('local-a', const [], ChatStorageKind.openWebUi));
      container
          .read(activeConversationInPlaceRemapProvider.notifier)
          .mark(fromId: 'local-a', toId: 'server-id');

      container.updateOverrides([
        appDatabaseProvider.overrideWith((ref) => dbB),
        apiServiceProvider.overrideWithValue(apiB),
      ]);
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('server-id', const [], ChatStorageKind.openWebUi));

      check(
        isActiveConversationInPlaceRemap(container, 'local-a', 'server-id'),
      ).isFalse();
    },
  );

  test(
    'OpenWebUI storage keeps its remap fence after a direct transport turn',
    () {
      final api = _GatedCompletionApi(Completer<void>()..complete());
      final epoch = Object();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiServiceProvider.overrideWithValue(api),
          openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation(
              'local-direct-turn',
              const <ChatMessage>[],
              ChatStorageKind.openWebUi,
              backend: kDirectTransport,
            ),
          );

      container
          .read(activeConversationProvider.notifier)
          .remapIdInPlace(
            fromId: 'local-direct-turn',
            toId: 'server-direct-turn',
          );

      final remap = container.read(activeConversationInPlaceRemapProvider);
      check(remap).isNotNull();
      check(
        remap!.namespace,
      ).equals(ActiveConversationRemapNamespace.openWebUi);
      check(remap.openWebUiDatabase).identicalTo(db);
      check(remap.openWebUiApi).identicalTo(api);
      check(remap.openWebUiAuthSessionEpoch).identicalTo(epoch);
      check(
        isActiveConversationInPlaceRemap(
          container,
          'local-direct-turn',
          'server-direct-turn',
        ),
      ).isTrue();
    },
  );

  test(
    'OpenWebUI storage keeps passive sync after a direct transport turn',
    () {
      final api = _GatedCompletionApi(Completer<void>()..complete());
      final socket = _CountingPassiveSocketService();
      addTearDown(socket.dispose);
      final active = _conversation(
        'server-direct-turn',
        <ChatMessage>[_user('user-direct-turn', 'Hello')],
        ChatStorageKind.openWebUi,
        backend: kDirectTransport,
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiServiceProvider.overrideWithValue(api),
          socketServiceProvider.overrideWithValue(socket),
          activeConversationProvider.overrideWith(() => _SeededActive(active)),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();

      check(container.read(chatMessagesProvider)).deepEquals(active.messages);
      check(socket.chatRegistrationCalls).equals(1);
    },
  );

  test('Hermes remap cannot disguise a later direct conversation switch', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final hermes = Conversation(
      id: 'shared-from',
      title: 'Hermes',
      createdAt: DateTime.utc(2026, 7, 13),
      updatedAt: DateTime.utc(2026, 7, 13),
      metadata: const <String, dynamic>{'backend': 'hermes'},
    );
    container.read(activeConversationProvider.notifier).set(hermes);
    container
        .read(activeConversationInPlaceRemapProvider.notifier)
        .mark(
          fromId: 'shared-from',
          toId: 'shared-to',
          namespace: ActiveConversationRemapNamespace.hermes,
        );
    container
        .read(activeConversationProvider.notifier)
        .set(_conversation('shared-to', const [], ChatStorageKind.directLocal));

    check(
      isActiveConversationInPlaceRemap(container, 'shared-from', 'shared-to'),
    ).isFalse();
  });

  test(
    'same-id server switch tears down A and rejects a late A database emission',
    () async {
      const chatId = 'same-live-chat';
      const assistantId = 'same-live-assistant';
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      await _seedChat(
        db,
        chatId,
        assistantId: assistantId,
        assistantContent: 'A original',
      );
      await _seedChat(
        dbB,
        chatId,
        assistantId: assistantId,
        assistantContent: 'B exact bytes',
      );
      final apiA = _GatedCompletionApi(Completer<void>()..complete());
      final apiB = _GatedCompletionApi(Completer<void>()..complete());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(apiA),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      final aMessages = <ChatMessage>[
        _streamingAssistant(assistantId, 'A original'),
      ];
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation(chatId, aMessages, ChatStorageKind.openWebUi));
      container.read(chatMessagesProvider);
      final notifier = container.read(chatMessagesProvider.notifier);
      var transportDisposals = 0;
      notifier.setSocketSubscriptions(assistantId, <void Function()>[
        () => transportDisposals++,
      ]);

      final bMessages = <ChatMessage>[
        _streamingAssistant(assistantId, 'B exact bytes'),
      ];
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation(chatId, bMessages, ChatStorageKind.openWebUi));
      container.updateOverrides([
        appDatabaseProvider.overrideWith((ref) => dbB),
        apiServiceProvider.overrideWithValue(apiB),
        socketServiceProvider.overrideWithValue(null),
      ]);
      await Future<void>.delayed(Duration.zero);

      await db.messagesDao.upsertLocalEcho(
        MessageRowData(
          id: assistantId,
          chatId: chatId,
          role: 'assistant',
          content: 'late A database bytes',
          createdAt: 2,
          orderIndex: 1,
          payload: const <String, dynamic>{
            'id': assistantId,
            'role': 'assistant',
            'content': 'late A database bytes',
            'timestamp': 2,
            'done': true,
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      check(transportDisposals).equals(1);
      check(
        container
            .read(chatMessagesProvider)
            .every((message) => message.content != 'late A database bytes'),
      ).isTrue();
      check(
        container.read(activeConversationProvider)!.messages.single.content,
      ).equals('B exact bytes');
    },
  );

  test(
    'direct transport in OpenWebUI storage tears down with its account context',
    () async {
      const chatId = 'direct-in-openwebui';
      const assistantId = 'direct-in-openwebui-assistant';
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      await _seedChat(
        db,
        chatId,
        assistantId: assistantId,
        assistantContent: 'A direct bytes',
      );
      await _seedChat(
        dbB,
        chatId,
        assistantId: assistantId,
        assistantContent: 'B exact bytes',
      );
      final apiA = _GatedCompletionApi(Completer<void>()..complete());
      final apiB = _GatedCompletionApi(Completer<void>()..complete());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          apiServiceProvider.overrideWithValue(apiA),
          socketServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      container.read(openWebUiDatabaseAccessProvider.notifier).open();
      final aMessages = <ChatMessage>[
        _streamingAssistant(assistantId, 'A direct bytes'),
      ];
      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation(
              chatId,
              aMessages,
              ChatStorageKind.openWebUi,
              backend: kDirectTransport,
            ),
          );
      container.read(chatMessagesProvider);
      final notifier = container.read(chatMessagesProvider.notifier);
      var transportDisposals = 0;
      notifier.setSocketSubscriptions(assistantId, <void Function()>[
        () => transportDisposals++,
      ]);

      final bMessages = <ChatMessage>[
        _streamingAssistant(assistantId, 'B exact bytes'),
      ];
      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation(
              chatId,
              bMessages,
              ChatStorageKind.openWebUi,
              backend: kDirectTransport,
            ),
          );
      container.updateOverrides([
        appDatabaseProvider.overrideWith((ref) => dbB),
        apiServiceProvider.overrideWithValue(apiB),
        socketServiceProvider.overrideWithValue(null),
      ]);
      await Future<void>.delayed(Duration.zero);

      await db.messagesDao.upsertLocalEcho(
        MessageRowData(
          id: assistantId,
          chatId: chatId,
          role: 'assistant',
          content: 'late A direct bytes',
          createdAt: 2,
          orderIndex: 1,
          payload: const <String, dynamic>{
            'id': assistantId,
            'role': 'assistant',
            'content': 'late A direct bytes',
            'timestamp': 2,
            'done': true,
          },
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      check(transportDisposals).equals(1);
      check(
        container
            .read(chatMessagesProvider)
            .every((message) => message.content != 'late A direct bytes'),
      ).isTrue();
      check(
        container.read(activeConversationProvider)!.messages.single.content,
      ).equals('B exact bytes');
    },
  );

  test(
    'pull fallback never crosses into the API selected after its await',
    () async {
      final dbB = AppDatabase(NativeDatabase.memory());
      addTearDown(dbB.close);
      final apiA = _CountingConversationApi('pull-a');
      final apiB = _CountingConversationApi('pull-b');
      final sync = _GatedNullPullSyncEngine();
      final authEpoch = Object();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiServiceProvider.overrideWithValue(apiA),
          syncEngineProvider.overrideWith(() => sync),
          openWebUiAuthSessionEpochProvider.overrideWithValue(authEpoch),
        ],
      );
      addTearDown(container.dispose);

      final pull = pullChatOrFetch(container, 'same-chat-id');
      await sync.entered.future;
      container.updateOverrides([
        appDatabaseProvider.overrideWithValue(dbB),
        apiServiceProvider.overrideWithValue(apiB),
        syncEngineProvider.overrideWith(_GatedNullPullSyncEngine.new),
        openWebUiAuthSessionEpochProvider.overrideWithValue(authEpoch),
      ]);
      sync.release.complete();

      check(await pull).isNull();
      check(apiA.getConversationCalls).equals(0);
      check(apiB.getConversationCalls).equals(0);
    },
  );
}
