import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/database/local_conversation_loader.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart' show ApiAuthSnapshot;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/moa_completion.dart';
import 'package:conduit_core/services/openwebui_stream_parser.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/request_completion_runner_provider.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/features/chat/providers/remap_route_sync_provider.dart';
import 'package:conduit_core/testing.dart'
    show FakeOpenWebUiServer, FakeSyncApiClient, openWebUiStorageOpenOverrides;
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/chat/services/request_completion_runner.dart';
import 'package:conduit_core/features/chat/services/chat_draft_queue.dart';
import 'package:conduit_core/features/chat/services/chat_transport_dispatch.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/personal_tool_execution.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this.initial);

  final Conversation? initial;

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
  void bufferLastMessageContent(String content, {bool immediate = true}) {
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

class _SignInEpoch extends Notifier<Object> {
  @override
  Object build() => Object();

  /// A new sign-in session: another account, or the same one signing back in.
  void rotate() => state = Object();
}

final _signInEpochProvider = NotifierProvider<_SignInEpoch, Object>(
  _SignInEpoch.new,
);

const _accountA = User(
  id: 'account-a',
  username: 'A',
  email: 'a@example.test',
  role: 'user',
);
const _accountB = User(
  id: 'account-b',
  username: 'B',
  email: 'b@example.test',
  role: 'user',
);

const _admin = User(
  id: 'admin',
  username: 'admin',
  email: 'admin@example.test',
  role: 'admin',
);

/// Who is signed in, switchable mid-test; starts as account A unless told.
class _SwitchableAccount extends Notifier<User?> {
  _SwitchableAccount([this._initial = _accountA]);

  final User _initial;

  @override
  User? build() => _initial;

  void switchToB() => state = _accountB;
  void signIn(User account) => state = account;
}

final _switchableAccountProvider = NotifierProvider<_SwitchableAccount, User?>(
  _SwitchableAccount.new,
);

/// Signs [account] in, switchable through [_switchableAccountProvider].
List<Override> _signedInAs(User account) => [
  _switchableAccountProvider.overrideWith(() => _SwitchableAccount(account)),
  currentUserProvider2.overrideWith(
    (ref) => ref.watch(_switchableAccountProvider),
  ),
];

/// What [_PersistingSyncEngine] needs from an API double to land the answer.
abstract interface class _AssistantIdSource {
  String? get assistantMessageId;
}

/// `/api/config` as Open WebUI 0.11.4 publishes it to a signed-in account.
Map<String, dynamic> _interpreterConfig({
  bool enabled = true,
  String engine = 'jupyter',
}) => <String, dynamic>{
  'status': true,
  'version': '0.11.4',
  'features': <String, dynamic>{
    'auth': true,
    'enable_websocket': true,
    'enable_code_interpreter': enabled,
  },
  'code': <String, dynamic>{'engine': 'pyodide', 'interpreter_engine': engine},
};

Map<String, dynamic> _interpreterPermissions({bool allowed = true}) =>
    <String, dynamic>{
      'features': <String, dynamic>{
        'web_search': true,
        'code_interpreter': allowed,
      },
    };

/// The cached configuration as the app's own refresh produces it: fetched from
/// the server and tagged with the server it came from.
class _FetchedConfig extends BackendConfigNotifier {
  _FetchedConfig(this.api);

  final ApiService api;

  @override
  Future<BackendConfig?> build() async =>
      (await api.getBackendConfig())?.copyWith(serverId: api.serverConfig.id);
}

/// A real [ApiService] whose HTTP layer is an in-memory server: it serves the
/// user's settings document, answers `/api/chat/completions` with a finished
/// completion and keeps the request bodies it was sent. Nothing between the
/// chat providers and the wire is replaced, so what it records is what Open
/// WebUI would have received.
class _WireCompletionApi extends ApiService implements _AssistantIdSource {
  _WireCompletionApi({
    Map<String, dynamic> settings = const {},
    bool keepAuthInterceptor = false,
  }) : settings = Map<String, dynamic>.of(settings),
       super(
         serverConfig: const ServerConfig(
           id: 'wire-server',
           name: 'Wire server',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       ) {
    dio.httpClientAdapter = _WireAdapter(this);
    // The auth interceptor refuses to send without a signed-in session. A test
    // that is about which account's token a request carries keeps it.
    if (!keepAuthInterceptor) dio.interceptors.clear();
  }

  /// The user's settings document the server currently returns.
  Map<String, dynamic> settings;
  int settingsReads = 0;
  final List<Map<String, dynamic>> completionBodies = [];

  /// Every path the server was asked for, in order.
  final List<String> paths = [];

  /// What the server says about its code interpreter, as `/api/config` does for
  /// a signed-in account, and about the account's permission for it.
  Map<String, dynamic> configBody = _interpreterConfig();
  Map<String, dynamic> permissionsBody = _interpreterPermissions();
  bool configFails = false;

  /// The server's model list, as `/api/models` returns it. Not served (404)
  /// until a test sets it.
  Map<String, dynamic>? modelsBody;

  /// Runs while the server is answering `/api/config`, before the response
  /// reaches the client: the moment another account can sign in.
  void Function()? duringConfig;

  /// The `Authorization` header every request arrived with, by path.
  final List<({String path, String? authorization})> credentials = [];

  @override
  String? get assistantMessageId =>
      completionBodies.isEmpty ? null : completionBodies.last['id'] as String?;

  Map<String, dynamic> get sentBody => completionBodies.last;

  Map<String, dynamic> get sentParams =>
      sentBody['params'] as Map<String, dynamic>;

  /// The request carries no `messages` at all when there is nothing but
  /// history for the server to rebuild.
  String? get sentSystem => ((sentBody['messages'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .where((message) => message['role'] == 'system')
      .map((message) => message['content'] as String)
      .firstOrNull;

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async => const [];
}

class _WireAdapter implements HttpClientAdapter {
  _WireAdapter(this.api);

  final _WireCompletionApi api;

  ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) async {
    api.paths.add(options.path);
    api.credentials.add((
      path: options.path,
      authorization: options.headers['Authorization'] as String?,
    ));
    switch (options.path) {
      case '/api/config':
        api.duringConfig?.call();
        return api.configFails
            ? _json(const <String, dynamic>{}, status: 503)
            : _json(api.configBody);
      case '/api/models':
        final models = api.modelsBody;
        return models == null
            ? _json(const <String, dynamic>{}, status: 404)
            : _json(models);
      case '/api/v1/users/permissions':
        return _json(api.permissionsBody);
      case '/api/v1/users/user/settings':
        api.settingsReads += 1;
        return _json(api.settings);
      case '/api/chat/completions':
        api.completionBodies.add(
          jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>,
        );
        return _json(<String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': 'A safely completed'},
            },
          ],
        });
    }
    return _json(const <String, dynamic>{}, status: 404);
  }

  @override
  void close({bool force = false}) {}
}

/// Lets everything through to [inner] except the settings read, which fails
/// like an unreachable server.
class _FailingSettingsAdapter implements HttpClientAdapter {
  _FailingSettingsAdapter(this.inner);

  final HttpClientAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelOnError,
  ) {
    if (options.path == '/api/v1/users/user/settings') {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'unreachable',
      );
    }
    return inner.fetch(options, requestStream, cancelOnError);
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
}

class _GatedCompletionApi extends ApiService implements _AssistantIdSource {
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
  @override
  String? assistantMessageId;
  String? submittedModel;
  Map<String, dynamic>? submittedModelItem;
  Map<String, dynamic>? submittedUserMessage;
  String? submittedSessionId;
  bool? submittedVoiceMode;
  List<Map<String, dynamic>>? submittedToolServers;
  List<Map<String, dynamic>>? submittedMessages;
  Map<String, dynamic>? submittedChatParams;
  Map<String, dynamic>? submittedUserSettings;
  Map<String, dynamic>? submittedGlobalParams;
  String? submittedReasoningEffort;

  /// The user's settings document, as the server would return it.
  Map<String, dynamic> settings = const {};

  Map<String, dynamic>? createdChatParams;

  @override
  Future<Conversation> createConversation({
    required String title,
    required List<ChatMessage> messages,
    String? model,
    String? systemPrompt,
    String? folderId,
    Map<String, dynamic>? chatParams,
  }) async {
    createdChatParams = chatParams == null
        ? null
        : Map<String, dynamic>.of(chatParams);
    return Conversation(
      id: 'server-new-chat',
      title: title,
      createdAt: DateTime.utc(2026, 7, 13),
      updatedAt: DateTime.utc(2026, 7, 13),
      folderId: folderId,
    );
  }

  /// Runs as the completion request leaves, before the server could answer.
  void Function()? onSend;

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async =>
      settings;

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
    assistantMessageId = responseMessageId;
    submittedMessages = [
      for (final message in messages) Map<String, dynamic>.of(message),
    ];
    submittedChatParams = chatParams == null
        ? null
        : Map<String, dynamic>.of(chatParams);
    submittedUserSettings = userSettings;
    submittedGlobalParams = globalParams;
    submittedReasoningEffort = reasoningEffort;
    submittedModel = model;
    submittedModelItem = modelItem == null
        ? null
        : Map<String, dynamic>.from(modelItem);
    submittedUserMessage = userMessage == null
        ? null
        : Map<String, dynamic>.from(userMessage);
    submittedSessionId = sessionIdOverride;
    submittedVoiceMode = isVoiceMode;
    submittedToolServers = toolServers;
    onSend?.call();
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
    bool keepsAliveInBackground = false,
    SocketReplayGapCallback? onReplayGap,
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
    bool keepsAliveInBackground = false,
    SocketReplayGapCallback? onReplayGap,
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

/// A connected socket that records the personal connections each chat request
/// admitted for Open WebUI's `execute:tool` callbacks.
class _AdmissionRecordingSocketService extends _CountingPassiveSocketService {
  final List<_RecordedAdmission> admissions = <_RecordedAdmission>[];

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

typedef _RecordedAdmission = ({
  String? chatId,
  String messageId,
  String? sessionId,
  List<PersonalToolAdmission> connections,
});

class _CountingDirectAdapter implements DirectProviderAdapter {
  int completionCalls = 0;

  @override
  String get key => kOpenAiCompatibleAdapterKey;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const <DirectRemoteModel>[];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) {
    completionCalls += 1;
    throw StateError('Open WebUI direct routing used the native adapter.');
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
  final _AssistantIdSource api;
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

/// An engine whose outbox drain is a no-op, so a durable admission can be
/// inspected exactly as it was written, before any runner picks it up.
class _NoDrainSyncEngine extends _PersistingSyncEngine {
  _NoDrainSyncEngine(super.db, super.api);

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}
}

/// A no-op drain that notes when it ran, to see what happened before it.
class _OrderedDrainSyncEngine extends _PersistingSyncEngine {
  _OrderedDrainSyncEngine(super.db, super.api, this.events);

  final List<String> events;

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    events.add('drain');
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
  Future<Conversation> getConversation(String id, {ApiAuthSnapshot? authSnapshot}) async {
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
  Map<String, dynamic>? storedParams,
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
          rawExtra: storedParams == null
              ? const Value.absent()
              : Value(jsonEncode(<String, dynamic>{'params': storedParams})),
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
  required Conversation? active,
  required List<ChatMessage> messages,
  required ApiService api,
  required _PersistingSyncEngine syncEngine,
  List<Override> extraOverrides = const [],
  SocketService? socket,
  Model model = const Model(id: 'model-1', name: 'Model 1'),
  String? terminalId,
}) {
  final container = ProviderContainer(
    overrides: [
      ...extraOverrides,
      appDatabaseProvider.overrideWith((ref) => db),
      activeConversationProvider.overrideWith(() => _SeededActive(active)),
      chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
      apiServiceProvider.overrideWithValue(api),
      selectedModelProvider.overrideWithValue(model),
      reviewerModeProvider.overrideWithValue(false),
      socketServiceProvider.overrideWithValue(socket),
      temporaryChatEnabledProvider.overrideWith(_FalseTemporaryChat.new),
      webSearchEnabledProvider.overrideWith(_FalseWebSearch.new),
      imageGenerationEnabledProvider.overrideWith(_FalseImageGeneration.new),
      webSearchAvailableProvider.overrideWithValue(false),
      imageGenerationAvailableProvider.overrideWithValue(false),
      selectedFilterIdsProvider.overrideWithValue(const <String>[]),
      selectedTerminalIdProvider.overrideWithValue(terminalId),
      syncEngineProvider.overrideWith(() => syncEngine),
    ],
  );
  container.read(chatMessagesProvider.notifier).setMessages(messages);
  return container;
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('personal tool servers and terminals reach the completion request', () {
    late _OpenApiHost alpha;
    late _OpenApiHost beta;

    setUp(() async {
      alpha = await _OpenApiHost.start('Alpha');
      beta = await _OpenApiHost.start('Beta');
    });

    tearDown(() async {
      await alpha.close();
      await beta.close();
    });

    Map<String, dynamic> toolServer(
      String id,
      _OpenApiHost host, {
      required String key,
    }) => <String, dynamic>{
      'type': 'openapi',
      'url': host.url,
      'spec_type': 'url',
      'path': '/openapi.json',
      'auth_type': 'bearer',
      'key': key,
      'config': <String, dynamic>{'enable': true},
      'info': <String, dynamic>{'id': id, 'name': id},
    };

    Future<_GatedCompletionApi> runCompletion({
      required Map<String, dynamic> settings,
      List<String> toolIds = const <String>[],
      SocketService? socket,
      void Function()? onSend,
    }) async {
      const chatId = 'personal-connections-chat';
      const assistantId = 'personal-connections-assistant';
      await _seedChat(db, chatId, assistantId: assistantId);
      final api = _GatedCompletionApi(Completer<void>()..complete())
        ..settings = settings
        ..onSend = onSend;
      final messages = <ChatMessage>[
        _user('personal-connections-user', 'use my tools'),
        _streamingAssistant(assistantId, ''),
      ];
      final container = _container(
        db: db,
        active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
        messages: messages,
        api: api,
        syncEngine: _PersistingSyncEngine(db, api),
        socket: socket,
      );
      addTearDown(container.dispose);
      final runnerProvider = Provider<RequestCompletionRunner>(
        (ref) => ChatRequestCompletionRunner(ref),
      );
      await container
          .read(runnerProvider)
          .run(
            chatId: chatId,
            payload: RequestCompletionPayload(
              assistantMessageId: assistantId,
              model: 'model-1',
              toolIds: toolIds,
            ).toJson(),
          );
      return api;
    }

    test(
      'a selection keeps its server after the list is edited and reordered',
      () async {
        final before = <dynamic>[
          toolServer('alpha', alpha, key: 'alpha-key'),
          toolServer('beta', beta, key: 'beta-old-key'),
        ];
        // The user selected beta while it was second.
        final selected = personalToolServerSelectionId(before, 1);
        // Beta was then given a new key and moved to the front.
        final api = await runCompletion(
          settings: <String, dynamic>{
            'ui': <String, dynamic>{
              'toolServers': <dynamic>[
                toolServer('beta', beta, key: 'beta-new-key'),
                before[0],
              ],
            },
          },
          toolIds: <String>[selected],
        );

        final sent = api.submittedToolServers!;
        check(sent).length.equals(1);
        check(sent.single['url']).equals(beta.url);
        check(sent.single['info']['title']).equals('Beta');
        check(beta.authorizations).deepEquals(<String?>['Bearer beta-new-key']);
        check(alpha.authorizations).isEmpty();
      },
    );

    test('a selection of a server that is gone sends no server', () async {
      final before = <dynamic>[
        <String, dynamic>{
          ...toolServer('x', alpha, key: 'k'),
          'info': <String, dynamic>{'name': 'x'},
        },
        <String, dynamic>{
          ...toolServer('y', beta, key: 'k'),
          'info': <String, dynamic>{'name': 'y'},
        },
      ];
      final selectedX = personalToolServerSelectionId(before, 0);
      // x was deleted, so y now sits at the position the selection recorded.
      final api = await runCompletion(
        settings: <String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[before[1]],
          },
        },
        toolIds: <String>[selectedX],
      );

      check(api.submittedToolServers).isNull();
      check(alpha.authorizations).isEmpty();
      check(beta.authorizations).isEmpty();
    });

    test('a bare position from an older build never selects the keyless server now at that slot', () async {
      // `direct_server:0` was taken from a list whose first server has since
      // been deleted. Nothing shows which server it named, so the keyless
      // server that now sits at 0 must not be sent or contacted.
      const chatId = 'personal-connections-bare-chat';
      const assistantId = 'personal-connections-bare-assistant';
      await _seedChat(db, chatId, assistantId: assistantId);
      final replacement = <String, dynamic>{
        ...toolServer('y', beta, key: 'beta-key'),
        'info': <String, dynamic>{'name': 'y'},
      };
      final api = _GatedCompletionApi(Completer<void>()..complete())
        ..settings = <String, dynamic>{
          'ui': <String, dynamic>{
            'toolServers': <dynamic>[replacement],
          },
        };
      final messages = <ChatMessage>[
        _user('personal-connections-bare-user', 'use my tools'),
        _streamingAssistant(assistantId, ''),
      ];
      final container = _container(
        db: db,
        active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
        messages: messages,
        api: api,
        syncEngine: _PersistingSyncEngine(db, api),
      );
      addTearDown(container.dispose);
      const selection = <String>['direct_server:0', 'calculator'];
      container.read(selectedToolIdsProvider.notifier).set(selection);

      await sendMessageWithContainer(container, 'hello', null, selection);

      check(api.submittedToolServers).isNull();
      check(beta.authorizations).isEmpty();
      check(container.read(selectedToolIdsProvider))
          .deepEquals(<String>['calculator']);
      check(container.read(personalSelectionNoticeProvider)).isNotEmpty();
    });

    test(
      'an unresolved selection is dropped and explained at the call',
      () async {
        const chatId = 'personal-connections-notice-chat';
        const assistantId = 'personal-connections-notice-assistant';
        await _seedChat(db, chatId, assistantId: assistantId);
        final api = _GatedCompletionApi(Completer<void>()..complete())
          ..settings = <String, dynamic>{
            'ui': <String, dynamic>{'toolServers': <dynamic>[]},
          };
        final messages = <ChatMessage>[
          _user('personal-connections-notice-user', 'use my tools'),
          _streamingAssistant(assistantId, ''),
        ];
        final container = _container(
          db: db,
          active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
          messages: messages,
          api: api,
          syncEngine: _PersistingSyncEngine(db, api),
        );
        addTearDown(container.dispose);
        const selection = <String>['direct_server:gone-server', 'calculator'];
        container.read(selectedToolIdsProvider.notifier).set(selection);

        await sendMessageWithContainer(container, 'hello', null, selection);

        check(api.submittedToolServers).isNull();
        check(container.read(selectedToolIdsProvider))
            .deepEquals(<String>['calculator']);
        check(container.read(personalSelectionNoticeProvider))
            .deepEquals(<String>['gone-server']);
      },
    );

    test(
      'an enabled personal terminal carries its edited key and url',
      () async {
        final api = await runCompletion(
          settings: <String, dynamic>{
            'ui': <String, dynamic>{
              'terminalServers': <dynamic>[
                <String, dynamic>{
                  'url': alpha.url,
                  'key': 'terminal-new-key',
                  'path': '/openapi.json',
                  'auth_type': 'bearer',
                  'enabled': true,
                  'config': <String, dynamic>{},
                },
              ],
            },
            // A stale list from an older client must not be sent.
            'terminalServers': <dynamic>[
              <String, dynamic>{
                'url': beta.url,
                'key': 'terminal-old-key',
                'path': '/openapi.json',
                'enabled': true,
              },
            ],
          },
        );

        final sent = api.submittedToolServers!.single;
        check(sent['url']).equals(alpha.url);
        check(sent['key']).equals('terminal-new-key');
        check(sent['is_terminal']).equals(true);
        check(alpha.authorizations)
            .deepEquals(<String?>['Bearer terminal-new-key']);
        check(beta.authorizations).isEmpty();
      },
    );

    group(
      'the request admits what it sent for Open WebUI\'s tool callbacks',
      () {
        late _AdmissionRecordingSocketService socket;

        setUp(() => socket = _AdmissionRecordingSocketService());

        List<dynamic> twoServers() => <dynamic>[
          toolServer('alpha', alpha, key: 'alpha-key'),
          toolServer('beta', beta, key: 'beta-key'),
        ];

        test('a queued completion admits only the selected server, for its chat, message and session', () async {
          final before = twoServers();
          var admittedWhenSent = -1;
          final api = await runCompletion(
            settings: <String, dynamic>{
              'ui': <String, dynamic>{'toolServers': before},
            },
            toolIds: <String>[personalToolServerSelectionId(before, 1)],
            socket: socket,
            onSend: () => admittedWhenSent = socket.admissions.length,
          );

          // Recorded before the request left, so a callback cannot outrun it.
          check(admittedWhenSent).equals(1);
          check(api.submittedSessionId).equals('passive-socket');
          final admission = socket.admissions.single;
          check(admission.chatId).equals('personal-connections-chat');
          check(admission.messageId).equals('personal-connections-assistant');
          check(admission.sessionId).equals('passive-socket');
          final connection = admission.connections.single;
          check(connection.kind).equals(PersonalConnectionKind.toolServer);
          check(connection.identity).equals('beta');
          check(connection.url).equals(beta.url);
          check(connection.operations).deepEquals(<String>{'ping'});
          // The server that was configured but not selected is not admitted.
          check(api.submittedToolServers!.map((s) => s['url']))
              .deepEquals(<Object?>[beta.url]);
        });

        test('a terminal is admitted as a terminal, by its URL', () async {
          await runCompletion(
            settings: <String, dynamic>{
              'ui': <String, dynamic>{
                'terminalServers': <dynamic>[
                  <String, dynamic>{
                    'url': alpha.url,
                    'key': 'terminal-key',
                    'path': '/openapi.json',
                    'auth_type': 'bearer',
                    'enabled': true,
                    'config': <String, dynamic>{},
                  },
                ],
              },
            },
            socket: socket,
          );

          final connection = socket.admissions.single.connections.single;
          check(connection.kind).equals(PersonalConnectionKind.terminal);
          check(connection.identity).equals('url:${alpha.url}');
          check(connection.operations).deepEquals(<String>{'ping'});
        });

        test(
          'a request that sends no personal server admits nothing',
          () async {
            await runCompletion(
              settings: <String, dynamic>{
                'ui': <String, dynamic>{'toolServers': twoServers()},
              },
              socket: socket,
            );

            check(socket.admissions).isEmpty();
          },
        );

        test(
          'an inline send admits for the chat and message it posted',
          () async {
            const chatId = 'personal-connections-inline-chat';
            const assistantId = 'personal-connections-inline-assistant';
            await _seedChat(db, chatId, assistantId: assistantId);
            final before = twoServers();
            final api = _GatedCompletionApi(Completer<void>()..complete())
              ..settings = <String, dynamic>{
                'ui': <String, dynamic>{'toolServers': before},
              };
            final messages = <ChatMessage>[
              _user('personal-connections-inline-user', 'use my tools'),
              _streamingAssistant(assistantId, ''),
            ];
            final container = _container(
              db: db,
              active: _conversation(
                chatId,
                messages,
                ChatStorageKind.openWebUi,
              ),
              messages: messages,
              api: api,
              syncEngine: _PersistingSyncEngine(db, api),
              socket: socket,
            );
            addTearDown(container.dispose);
            final selection = <String>[
              personalToolServerSelectionId(before, 0),
            ];
            container.read(selectedToolIdsProvider.notifier).set(selection);

            await sendMessageWithContainer(container, 'hello', null, selection);

            final admission = socket.admissions.single;
            check(admission.chatId).equals(chatId);
            check(admission.messageId).equals(api.assistantMessageId!);
            check(admission.sessionId).equals(api.submittedSessionId);
            check(admission.connections.single.identity).equals('alpha');
            check(admission.connections.single.url).equals(alpha.url);
          },
        );

        test('a headless completion admits for the chat it runs in', () async {
          const chatId = 'personal-connections-headless-chat';
          const assistantId = 'personal-connections-headless-assistant';
          await _seedChat(db, chatId, assistantId: assistantId);
          final before = twoServers();
          final api = _GatedCompletionApi(Completer<void>()..complete())
            ..settings = <String, dynamic>{
              'ui': <String, dynamic>{'toolServers': before},
            };
          final foregroundMessages = <ChatMessage>[
            _user('foreground-user', 'different chat'),
          ];
          final container = _container(
            db: db,
            active: _conversation(
              'foreground-chat',
              foregroundMessages,
              ChatStorageKind.openWebUi,
            ),
            messages: foregroundMessages,
            api: api,
            syncEngine: _PersistingSyncEngine(db, api),
            socket: socket,
          );
          addTearDown(container.dispose);
          final runnerProvider = Provider<RequestCompletionRunner>(
            (ref) => ChatRequestCompletionRunner(ref),
          );

          await container
              .read(runnerProvider)
              .run(
                chatId: chatId,
                payload: RequestCompletionPayload(
                  assistantMessageId: assistantId,
                  model: 'model-1',
                  toolIds: <String>[personalToolServerSelectionId(before, 1)],
                ).toJson(),
              );

          final admission = socket.admissions.single;
          check(admission.chatId).equals(chatId);
          check(admission.messageId).equals(assistantId);
          check(admission.sessionId).equals('passive-socket');
          check(admission.connections.single.identity).equals('beta');
        });
      },
    );
  });

  test('completion runner preserves voice mode for a live request', () async {
    const chatId = 'voice-live-chat';
    const assistantId = 'voice-live-assistant';
    await _seedChat(db, chatId, assistantId: assistantId);
    final api = _GatedCompletionApi(Completer<void>()..complete());
    final messages = <ChatMessage>[
      _user('voice-live-user', 'hello by voice'),
      _streamingAssistant(assistantId, ''),
    ];
    final container = _container(
      db: db,
      active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
      messages: messages,
      api: api,
      syncEngine: _PersistingSyncEngine(db, api),
    );
    addTearDown(container.dispose);
    final runnerProvider = Provider<RequestCompletionRunner>(
      (ref) => ChatRequestCompletionRunner(ref),
    );

    await container
        .read(runnerProvider)
        .run(
          chatId: chatId,
          payload: const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            isVoiceMode: true,
          ).toJson(),
        );

    check(api.submittedVoiceMode).equals(true);
  });

  test(
    'completion runner preserves voice mode for a headless request',
    () async {
      const chatId = 'voice-headless-chat';
      const assistantId = 'voice-headless-assistant';
      await _seedChat(db, chatId, assistantId: assistantId);
      final api = _GatedCompletionApi(Completer<void>()..complete());
      final foregroundMessages = <ChatMessage>[
        _user('foreground-user', 'different chat'),
      ];
      final container = _container(
        db: db,
        active: _conversation(
          'foreground-chat',
          foregroundMessages,
          ChatStorageKind.openWebUi,
        ),
        messages: foregroundMessages,
        api: api,
        syncEngine: _PersistingSyncEngine(db, api),
      );
      addTearDown(container.dispose);
      final runnerProvider = Provider<RequestCompletionRunner>(
        (ref) => ChatRequestCompletionRunner(ref),
      );

      await container
          .read(runnerProvider)
          .run(
            chatId: chatId,
            payload: const RequestCompletionPayload(
              assistantMessageId: assistantId,
              model: 'model-1',
              isVoiceMode: true,
            ).toJson(),
          );

      check(api.submittedVoiceMode).equals(true);
    },
  );

  test(
    'Open WebUI direct send uses the server pipeline and upstream wire model',
    () async {
      const chatId = 'openwebui-direct-chat';
      await _seedChat(db, chatId);
      final releasePost = Completer<void>()..complete();
      final api = _GatedCompletionApi(releasePost);
      final socket = _CountingPassiveSocketService();
      final syncEngine = _PersistingSyncEngine(db, api);
      final profile = DirectConnectionProfile(
        id: 'openwebui-profile',
        name: 'Server direct connection',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'https://provider.example.test/v1',
        modelIdPrefix: 'server-prefix',
      );
      final registry = DirectModelRegistry();
      final selectedModel = registry
          .replaceProfileModels(
            profile,
            <DirectRemoteModel>[
              DirectRemoteModel(id: 'provider/model', name: 'Provider model'),
            ],
            source: DirectModelSource.openWebUi,
            openWebUiUrlIndex: 3,
          )
          .single;
      final nativeAdapter = _CountingDirectAdapter();
      final messages = <ChatMessage>[_user('existing-user', 'Existing turn')];
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          activeConversationProvider.overrideWith(
            () => _SeededActive(
              _conversation(chatId, messages, ChatStorageKind.openWebUi),
            ),
          ),
          chatMessagesProvider.overrideWith(_TestMessagesNotifier.new),
          apiServiceProvider.overrideWithValue(api),
          selectedModelProvider.overrideWithValue(selectedModel),
          reviewerModeProvider.overrideWithValue(false),
          socketServiceProvider.overrideWithValue(socket),
          temporaryChatEnabledProvider.overrideWith(_FalseTemporaryChat.new),
          webSearchEnabledProvider.overrideWith(_FalseWebSearch.new),
          imageGenerationEnabledProvider.overrideWith(
            _FalseImageGeneration.new,
          ),
          webSearchAvailableProvider.overrideWithValue(false),
          imageGenerationAvailableProvider.overrideWithValue(false),
          selectedFilterIdsProvider.overrideWithValue(const <String>[]),
          selectedTerminalIdProvider.overrideWithValue(null),
          syncEngineProvider.overrideWith(() => syncEngine),
          directModelRegistryProvider.overrideWithValue(registry),
          effectiveDirectConnectionProfilesFutureProvider.overrideWith(
            (ref) async => <DirectConnectionProfile>[profile],
          ),
          directProviderAdapterRegistryProvider.overrideWithValue(
            DirectProviderAdapterRegistry(<DirectProviderAdapter>[
              nativeAdapter,
            ]),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(chatMessagesProvider.notifier).setMessages(messages);

      await sendMessageWithContainer(container, 'Use the server relay', null);

      check(api.completionCalls).equals(1);
      check(api.submittedModel).equals('server-prefix.provider/model');
      check(api.submittedSessionId).equals('passive-socket');
      final modelItem = api.submittedModelItem!;
      check(modelItem['id'] as String).equals('server-prefix.provider/model');
      check(modelItem['direct'] as bool).isTrue();
      check(modelItem['urlIdx'] as int).equals(3);
      check(modelItem['openai'] as Map<String, dynamic>)
          .deepEquals(<String, dynamic>{'id': 'provider/model'});
      check(modelItem['connection_type'] as String).equals('external');
      check((api.submittedUserMessage!['models'] as List).cast<String>())
          .contains('server-prefix.provider/model');
      check(nativeAdapter.completionCalls).equals(0);
    },
  );

  test('inline POST navigation continues A headlessly without touching colliding B', () async {
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
    check(container.read(contextAttachmentsProvider).single.id)
        .equals('b-note');
    final persisted = await db.messagesDao.getMessage(chatId, assistantId);
    check(persisted).isNotNull();
    check(persisted!.content).equals('A safely completed');
  });

  test('queued POST navigation continues A headlessly without touching colliding B', () async {
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
  });

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

      check(container.read(activeChatIdsProvider))
          .not((activeIds) => activeIds.contains('chat-a'));
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

      final notifier = container.read(
        chatMessagesProvider.notifier,
      ) as _TestMessagesNotifier;
      check(attached).isTrue();
      check(container.read(chatMessagesProvider).single.content)
          .equals('Already completed');
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

      check(isActiveConversationInPlaceRemap(container, 'local-a', 'server-id'))
          .isFalse();
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
      check(remap!.namespace)
          .equals(ActiveConversationRemapNamespace.openWebUi);
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
      check(container.read(activeConversationProvider)!.messages.single.content)
          .equals('B exact bytes');
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
      check(container.read(activeConversationProvider)!.messages.single.content)
          .equals('B exact bytes');
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

  group('saved chat settings reach every Open WebUI request path', () {
    const chatId = 'settings-chat';
    const assistantId = 'settings-assistant';

    Future<_GatedCompletionApi> replay({
      required RequestCompletionPayload payload,
      Map<String, dynamic>? storedParams,
      required bool foreground,
      Map<String, dynamic> globalSettings = const {},
      Map<String, dynamic> foregroundParams = const {},
      String? legacySystem,
    }) async {
      await _seedChat(
        db,
        chatId,
        assistantId: assistantId,
        storedParams: storedParams,
      );
      final api = _GatedCompletionApi(Completer<void>()..complete())
        ..settings = globalSettings;
      final messages = foreground
          ? <ChatMessage>[
              _user('settings-user', 'hello'),
              _streamingAssistant(assistantId, ''),
            ]
          : <ChatMessage>[_user('foreground-user', 'a different chat')];
      final active =
          _conversation(
            foreground ? chatId : 'foreground-chat',
            messages,
            ChatStorageKind.openWebUi,
          ).copyWith(
            chatParams: foreground ? const {} : foregroundParams,
            systemPrompt: foreground ? legacySystem : null,
          );
      final container = _container(
        db: db,
        active: active,
        messages: messages,
        api: api,
        syncEngine: _PersistingSyncEngine(db, api),
      );
      addTearDown(container.dispose);
      await container
          .read(
            Provider<RequestCompletionRunner>(
              (ref) => ChatRequestCompletionRunner(ref),
            ),
          )
          .run(chatId: chatId, payload: payload.toJson());
      return api;
    }

    RequestCompletionPayload payloadWith(
      OpenWebUiChatSettingsSnapshot? snapshot,
    ) => RequestCompletionPayload(
      assistantMessageId: assistantId,
      model: 'model-1',
      chatSettings: snapshot,
    );

    String? systemOf(_GatedCompletionApi api) => api.submittedMessages
        ?.where((m) => m['role'] == 'system')
        .map((m) => m['content'] as String)
        .firstOrNull;

    for (final foreground in [true, false]) {
      final path = foreground ? 'live' : 'headless';

      test(
        '$path replay uses the admitted settings, not a later edit',
        () async {
          final api = await replay(
            foreground: foreground,
            storedParams: {'system': 'Edited later', 'temperature': 0.9},
            payload: payloadWith(
              OpenWebUiChatSettingsSnapshot(
                params: {'system': 'Admitted', 'temperature': 0.1},
                reasoningEffort: 'high',
              ),
            ),
          );

          check(api.submittedChatParams)
              .isNotNull()
              .deepEquals({'system': 'Admitted', 'temperature': 0.1});
          check(systemOf(api)).equals('Admitted');
          check(api.submittedReasoningEffort).equals('high');
        },
      );

      test(
        '$path replay of an older op reads the chat\'s stored params',
        () async {
          final api = await replay(
            foreground: foreground,
            storedParams: {'system': 'Stored', 'seed': 5},
            payload: payloadWith(null),
          );

          check(api.submittedChatParams)
              .isNotNull()
              .deepEquals({'system': 'Stored', 'seed': 5});
          check(systemOf(api)).equals('Stored');
        },
      );

      test(
        '$path replay of an empty snapshot ignores params gained since',
        () async {
          final api = await replay(
            foreground: foreground,
            storedParams: {'system': 'Gained later', 'temperature': 0.9},
            payload: payloadWith(OpenWebUiChatSettingsSnapshot()),
          );

          check(api.submittedChatParams).isNotNull().isEmpty();
          check(systemOf(api)).isNull();
        },
      );

      test(
        '$path replay: an explicit empty system replaces the global prompt',
        () async {
          final api = await replay(
            foreground: foreground,
            payload: payloadWith(
              OpenWebUiChatSettingsSnapshot(params: {'system': ''}),
            ),
            globalSettings: {
              'ui': {'system': 'Global prompt'},
            },
          );

          check(api.submittedMessages).isNotNull().deepEquals([
            {'role': 'system', 'content': ''},
          ]);
        },
      );

      test(
        '$path replay: with no chat prompt the global one applies',
        () async {
          final api = await replay(
            foreground: foreground,
            payload: payloadWith(OpenWebUiChatSettingsSnapshot()),
            globalSettings: {
              'ui': {'system': 'Global prompt'},
            },
          );

          check(systemOf(api)).equals('Global prompt');
        },
      );
    }

    test(
      'headless replay reads the target chat, never the one on screen',
      () async {
        final api = await replay(
          foreground: false,
          storedParams: {'seed': 1},
          foregroundParams: {'seed': 2, 'system': 'ON SCREEN'},
          payload: payloadWith(null),
        );

        check(api.submittedChatParams).isNotNull().deepEquals({'seed': 1});
        check(systemOf(api)).isNull();
      },
    );

    test(
      'live replay keeps the legacy chat.system when params have none',
      () async {
        final api = await replay(
          foreground: true,
          legacySystem: 'Legacy prompt',
          payload: payloadWith(OpenWebUiChatSettingsSnapshot()),
        );

        check(systemOf(api)).equals('Legacy prompt');
      },
    );

    test(
      'inline send reads the stored params, not a stale in-memory copy',
      () async {
        await _seedChat(
          db,
          chatId,
          storedParams: {'seed': 5, 'system': 'Stored'},
        );
        final api = _GatedCompletionApi(Completer<void>()..complete());
        final messages = <ChatMessage>[_user('u0', 'earlier')];
        final container = _container(
          db: db,
          active: _conversation(
            chatId,
            messages,
            ChatStorageKind.openWebUi,
          ).copyWith(chatParams: {'seed': 0}),
          messages: messages,
          api: api,
          syncEngine: _PersistingSyncEngine(db, api),
        );
        addTearDown(container.dispose);

        await sendMessageWithContainer(container, 'next turn', null);

        check(api.submittedChatParams)
            .isNotNull()
            .deepEquals({'seed': 5, 'system': 'Stored'});
        check(systemOf(api)).equals('Stored');
      },
    );

    test(
      'inline send in a brand-new chat carries the draft settings',
      () async {
        final api = _GatedCompletionApi(Completer<void>()..complete());
        final container = _container(
          db: db,
          active: null,
          messages: const [],
          api: api,
          syncEngine: _PersistingSyncEngine(db, api),
        );
        addTearDown(container.dispose);
        container.read(pendingOpenWebUiChatSettingsProvider.notifier).replace({
          'system': 'Draft prompt',
          'temperature': 0.2,
        });

        await sendMessageWithContainer(container, 'first turn', null);

        check(api.createdChatParams)
            .isNotNull()
            .deepEquals({'system': 'Draft prompt', 'temperature': 0.2});
        check(api.submittedChatParams)
            .isNotNull()
            .deepEquals({'system': 'Draft prompt', 'temperature': 0.2});
        check(systemOf(api)).equals('Draft prompt');
        // The chat now exists and owns them; the draft does not linger.
        check(container.read(pendingOpenWebUiChatSettingsProvider)).isEmpty();
        check(container.read(activeConversationProvider)!.chatParams)
            .deepEquals({'system': 'Draft prompt', 'temperature': 0.2});
      },
    );

    test(
      'regeneration reads the stored params, not a stale in-memory copy',
      () async {
        await _seedChat(
          db,
          chatId,
          storedParams: {'seed': 5, 'system': 'Stored'},
        );
        final api = _GatedCompletionApi(Completer<void>()..complete());
        final messages = <ChatMessage>[
          _user('u1', 'question'),
          ChatMessage(
            id: 'a1',
            role: 'assistant',
            content: 'first answer',
            timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
            model: 'model-1',
          ),
        ];
        final container = _container(
          db: db,
          active: _conversation(
            chatId,
            messages,
            ChatStorageKind.openWebUi,
          ).copyWith(chatParams: {'seed': 0}),
          messages: messages,
          api: api,
          syncEngine: _PersistingSyncEngine(db, api),
        );
        addTearDown(container.dispose);

        await regenerateMessage(container, 'question', null);

        check(api.completionCalls).equals(1);
        check(api.submittedChatParams)
            .isNotNull()
            .deepEquals({'seed': 5, 'system': 'Stored'});
        check(systemOf(api)).equals('Stored');
      },
    );

    group('durable admission', () {
      Future<List<OutboxOp>> pendingOps(String id) =>
          db.outboxDao.pendingForChat(id);

      RequestCompletionPayload completionOf(List<OutboxOp> ops) =>
          RequestCompletionPayload.fromJson(
            jsonDecode(
              ops.singleWhere((op) => op.kind == 'requestCompletion').payload,
            ) as Map<String, dynamic>,
          );

      test('an existing chat is admitted with its stored settings and replays them', () async {
        await _seedChat(
          db,
          chatId,
          storedParams: {'temperature': 0.3, 'system': ''},
        );
        final api = _GatedCompletionApi(Completer<void>()..complete());
        final messages = <ChatMessage>[_user('u0', 'earlier')];
        final container = _container(
          db: db,
          active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
          messages: messages,
          api: api,
          syncEngine: _NoDrainSyncEngine(db, api),
        );
        addTearDown(container.dispose);

        await durableSend(container, 'queued turn', null);

        final admitted = completionOf(await pendingOps(chatId));
        check(admitted.chatSettings).isNotNull();
        check(admitted.chatSettings!.params)
            .deepEquals({'temperature': 0.3, 'system': ''});

        // The chat is edited after the user pressed send, before replay.
        await db.chatsDao.patchChatParamsWithOutbox(
          chatId,
          set: {'temperature': 1.7, 'system': 'Edited after'},
          updatedAt: 9,
        );
        final op = (await pendingOps(chatId))
            .singleWhere((op) => op.kind == 'requestCompletion');
        await container
            .read(
              Provider<RequestCompletionRunner>(
                (ref) => ChatRequestCompletionRunner(ref),
              ),
            )
            .run(
              chatId: chatId,
              payload: jsonDecode(op.payload) as Map<String, dynamic>,
            );

        check(api.submittedChatParams)
            .isNotNull()
            .deepEquals({'temperature': 0.3, 'system': ''});
      });

      test(
        'a chat with no params is admitted with an explicit empty snapshot',
        () async {
          await _seedChat(db, chatId);
          final api = _GatedCompletionApi(Completer<void>()..complete());
          final messages = <ChatMessage>[_user('u0', 'earlier')];
          final container = _container(
            db: db,
            active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
            messages: messages,
            api: api,
            syncEngine: _NoDrainSyncEngine(db, api),
          );
          addTearDown(container.dispose);

          await durableSend(container, 'queued turn', null);

          final admitted = completionOf(await pendingOps(chatId));
          check(admitted.chatSettings).isNotNull();
          check(admitted.chatSettings!.params).isEmpty();
        },
      );

      group('a committed admission is certified', () {
        test(
          'once the rows and the completion operation are committed, before the drain, naming that turn',
          () async {
            await _seedChat(db, chatId);
            final api = _GatedCompletionApi(Completer<void>()..complete());
            final events = <String>[];
            final engine = _OrderedDrainSyncEngine(db, api, events);
            final messages = <ChatMessage>[_user('u0', 'earlier')];
            final container = _container(
              db: db,
              active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
              messages: messages,
              api: api,
              syncEngine: engine,
            );
            addTearDown(container.dispose);

            ChatSendAdmissionReceipt? receipt;
            await durableSend(
              container,
              'queued turn',
              null,
              onAdmissionCommitted: (r) {
                events.add('receipt');
                receipt = r;
              },
            );

            check(events).deepEquals(['receipt', 'drain']);
            final stored = await db.messagesDao.getForChat(chatId);
            final ops = await pendingOps(chatId);
            check(receipt).isNotNull();
            check(receipt!.chatId).equals(chatId);
            check(
              stored.map((row) => row.id),
            ).contains(receipt!.userMessageId);
            check(
              stored.map((row) => row.id),
            ).contains(receipt!.assistantMessageId);
            check(completionOf(ops).assistantMessageId)
                .equals(receipt!.assistantMessageId);
            check(receipt!.owner.openWebUiApi).identicalTo(api);
          },
        );

        test(
          'a send that would take an inline path is refused before anything is written',
          () async {
            await _seedChat(db, chatId);
            final api = _GatedCompletionApi(Completer<void>()..complete());
            final messages = <ChatMessage>[_user('u0', 'earlier')];
            final container = _container(
              db: db,
              active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
              messages: messages,
              api: api,
              syncEngine: _NoDrainSyncEngine(db, api),
              // Not an Open WebUI model: ordinarily this goes inline.
              model: hermesSyntheticModel(),
            );
            addTearDown(container.dispose);

            var certified = false;
            await check(
              durableSend(
                container,
                'queued turn',
                null,
                onAdmissionCommitted: (_) => certified = true,
              ),
            ).throws<ChatAdmissionNotDurableException>();

            check(certified).isFalse();
            check(container.read(chatMessagesProvider)).length.equals(1);
            check(await db.messagesDao.getForChat(chatId)).isEmpty();
            check(await pendingOps(chatId)).isEmpty();
          },
        );
      });

      group('global defaults are frozen with the turn', () {
        const user = User(
          id: 'u1',
          username: 'u1',
          email: 'u1@example.test',
          role: 'user',
        );

        // The settings document as the browser saves it: generation defaults
        // and the prompt under `ui`, plus an older root-level `params` that
        // must lose to them.
        Map<String, dynamic> settingsDoc({
          required double temperature,
          required String system,
          String? stop,
        }) => {
          'ui': {
            'params': {'temperature': temperature, 'stop': ?stop},
            'system': system,
          },
          'params': {'temperature': 0.8, 'seed': 99},
        };

        Future<ProviderContainer> admit({
          required _WireCompletionApi api,
          required String chatId,
          required OpenWebUiUserSettingsCache cache,
          bool online = true,
          User account = user,
          Map<String, dynamic>? storedParams,
        }) async {
          await _seedChat(db, chatId, storedParams: storedParams);
          final messages = <ChatMessage>[_user('u0', 'earlier')];
          final container = _container(
            db: db,
            active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
            messages: messages,
            api: api,
            syncEngine: _NoDrainSyncEngine(db, api),
            extraOverrides: [
              isOnlineProvider.overrideWithValue(online),
              currentUserProvider2.overrideWithValue(account),
              openWebUiUserSettingsCacheProvider.overrideWithValue(cache),
            ],
          );
          addTearDown(container.dispose);
          await durableSend(container, 'queued turn', null);
          return container;
        }

        Future<void> replayQueued(ProviderContainer c, String chatId) async {
          final op = (await pendingOps(chatId))
              .singleWhere((op) => op.kind == 'requestCompletion');
          await c
              .read(
                Provider<RequestCompletionRunner>(
                  (ref) => ChatRequestCompletionRunner(ref),
                ),
              )
              .run(
                chatId: chatId,
                payload: jsonDecode(op.payload) as Map<String, dynamic>,
              );
        }

        test(
          'changed globals and prompts never reach the replayed request',
          () async {
            final api = _WireCompletionApi(
              settings: settingsDoc(
                temperature: 0.1,
                system: 'Prompt at send',
                stop: 'x, y',
              ),
            );
            final container = await admit(
              api: api,
              chatId: chatId,
              cache: OpenWebUiUserSettingsCache(),
              storedParams: {'seed': 5},
            );

            final admitted = completionOf(await pendingOps(chatId));
            // Stored as the server had it (ui.params, not the older root
            // params), with `stop` not yet normalized: that happens once, when
            // the request is composed.
            check(admitted.chatSettings!.baseline!.globalParams)
                .deepEquals({'temperature': 0.1, 'stop': 'x, y'});
            check(admitted.chatSettings!.baseline!.systemMessage)
                .equals('Prompt at send');

            // Before replay the user changes every global default and prompt,
            // here and on the server, and the chat's legacy prompt too.
            api.settings = settingsDoc(
              temperature: 0.9,
              system: 'Prompt changed later',
              stop: 'z',
            );
            container
                .read(activeConversationProvider.notifier)
                .set(
                  container
                      .read(activeConversationProvider)!
                      .copyWith(systemPrompt: 'Legacy prompt changed later'),
                );
            await replayQueued(container, chatId);

            check(api.completionBodies).length.equals(1);
            check(api.sentParams).deepEquals({
              'temperature': 0.1,
              'stop': ['x', 'y'],
              'seed': 5,
            });
            check(api.sentSystem).equals('Prompt at send');
          },
        );

        test('a chat prompt of its own is frozen the same way', () async {
          final api = _WireCompletionApi(
            settings: settingsDoc(temperature: 0.1, system: 'Global'),
          );
          final container = await admit(
            api: api,
            chatId: chatId,
            cache: OpenWebUiUserSettingsCache(),
            storedParams: {'system': ''},
          );

          api.settings = settingsDoc(temperature: 0.9, system: 'Other global');
          await replayQueued(container, chatId);

          // An explicit empty chat prompt replaced the global one at send time
          // and still does.
          check(api.sentSystem).equals('');
          check(api.sentParams).deepEquals({'temperature': 0.1, 'system': ''});
        });

        test(
          'offline, the account\'s last-seen defaults are admitted without a fetch',
          () async {
            final cache = OpenWebUiUserSettingsCache();
            // An earlier send, online, is where the app last saw the settings.
            await admit(
              api: _WireCompletionApi(
                settings: settingsDoc(temperature: 0.3, system: 'Last seen'),
              ),
              chatId: 'warm-chat',
              cache: cache,
            );

            final offlineApi = _WireCompletionApi(
              settings: settingsDoc(temperature: 0.9, system: 'Unreachable'),
            );
            final container = await admit(
              api: offlineApi,
              chatId: chatId,
              cache: cache,
              online: false,
            );

            check(offlineApi.settingsReads).equals(0);
            final baseline =
                completionOf(await pendingOps(chatId)).chatSettings!.baseline!;
            check(baseline.globalParams).deepEquals({'temperature': 0.3});
            check(baseline.systemMessage).equals('Last seen');

            // Connectivity returns and the server's settings differ by now.
            await replayQueued(container, chatId);
            check(offlineApi.sentParams).deepEquals({'temperature': 0.3});
            check(offlineApi.sentSystem).equals('Last seen');
          },
        );

        test(
          'offline with nothing seen for the account is admitted with none, '
          'and never gains them at replay',
          () async {
            final cache = OpenWebUiUserSettingsCache();
            await admit(
              api: _WireCompletionApi(
                settings: settingsDoc(temperature: 0.3, system: 'Account one'),
              ),
              chatId: 'warm-chat',
              cache: cache,
            );

            // Another account on the same server: it never reads the first's.
            const other = User(
              id: 'u2',
              username: 'u2',
              email: 'u2@example.test',
              role: 'user',
            );
            final api = _WireCompletionApi(
              settings: settingsDoc(temperature: 0.9, system: 'Account two'),
            );
            final container = await admit(
              api: api,
              chatId: chatId,
              cache: cache,
              online: false,
              account: other,
              storedParams: {'seed': 2},
            );

            final baseline =
                completionOf(await pendingOps(chatId)).chatSettings!.baseline!;
            check(baseline.globalParams).isEmpty();
            check(baseline.systemMessage).isNull();

            await replayQueued(container, chatId);
            check(api.sentParams).deepEquals({'seed': 2});
            check(api.sentSystem).isNull();
          },
        );

        test(
          'online, a server that does not answer falls back to the last-seen '
          'defaults',
          () async {
            final cache = OpenWebUiUserSettingsCache();
            await admit(
              api: _WireCompletionApi(
                settings: settingsDoc(temperature: 0.3, system: 'Last seen'),
              ),
              chatId: 'warm-chat',
              cache: cache,
            );

            final api = _WireCompletionApi();
            api.dio.httpClientAdapter = _FailingSettingsAdapter(
              api.dio.httpClientAdapter,
            );
            await admit(api: api, chatId: chatId, cache: cache);

            final baseline =
                completionOf(await pendingOps(chatId)).chatSettings!.baseline!;
            check(baseline.globalParams).deepEquals({'temperature': 0.3});
            check(baseline.systemMessage).equals('Last seen');
          },
        );

        test(
          'an account switch while the send prepares its files cannot recall '
          'the next account\'s cached defaults',
          () async {
            await _seedChat(db, chatId);
            final api = _WireCompletionApi();
            // Both accounts are known to the device, with different defaults.
            final cache = OpenWebUiUserSettingsCache()
              ..remember('wire-server\u0000${_accountA.id}', {
                'ui': {
                  'params': {'temperature': 0.2},
                  'system': 'A private prompt',
                },
              })
              ..remember('wire-server\u0000${_accountB.id}', {
                'ui': {
                  'params': {'temperature': 0.8},
                  'system': 'B private prompt',
                },
              });
            final messages = <ChatMessage>[_user('u0', 'earlier')];
            final container = _container(
              db: db,
              active: _conversation(
                chatId,
                messages,
                ChatStorageKind.openWebUi,
              ),
              messages: messages,
              api: api,
              syncEngine: _NoDrainSyncEngine(db, api),
              extraOverrides: [
                isOnlineProvider.overrideWithValue(false),
                currentUserProvider2.overrideWith(
                  (ref) => ref.watch(_switchableAccountProvider),
                ),
                openWebUiAuthSessionEpochProvider.overrideWith(
                  (ref) => ref.watch(_signInEpochProvider),
                ),
                openWebUiUserSettingsCacheProvider.overrideWithValue(cache),
              ],
            );
            addTearDown(container.dispose);

            // A sends. durableSend runs up to its first await (the empty
            // attachment preparation) before control returns here; B signs in
            // on the same server, API and database at exactly that point.
            final send = durableSend(container, 'started by A', null);
            container.read(_switchableAccountProvider.notifier).switchToB();
            container.read(_signInEpochProvider.notifier).rotate();
            await send;

            // The turn is still A's: admitted in A's chat with A's defaults,
            // never relabelled with B's private ones.
            final baseline = completionOf(await pendingOps(chatId))
                .chatSettings!
                .baseline!;
            check(baseline.globalParams).deepEquals({'temperature': 0.2});
            check(baseline.systemMessage).equals('A private prompt');

            // And what finally goes out on replay is that same frozen A turn.
            await replayQueued(container, chatId);
            check(api.completionBodies).length.equals(1);
            check(api.sentParams).deepEquals({'temperature': 0.2});
            check(api.sentSystem).equals('A private prompt');
          },
        );
      });

      test(
        'a new chat admitted by the next account does not inherit the '
        'previous account\'s draft',
        () async {
          final api = _GatedCompletionApi(Completer<void>()..complete());
          final container = _container(
            db: db,
            active: null,
            messages: const [],
            api: api,
            syncEngine: _NoDrainSyncEngine(db, api),
            extraOverrides: [
              openWebUiAuthSessionEpochProvider.overrideWith(
                (ref) => ref.watch(_signInEpochProvider),
              ),
            ],
          );
          addTearDown(container.dispose);
          container
              .read(pendingOpenWebUiChatSettingsProvider.notifier)
              .replace({'system': 'Account A prompt', 'temperature': 0.2});

          // Account B signs in on the same server: same API, same database.
          container.read(_signInEpochProvider.notifier).rotate();
          await durableSend(container, 'first turn from B', null);

          final created = container.read(activeConversationProvider)!;
          check(created.chatParams).isEmpty();
          check(await db.chatsDao.getChatParams(created.id))
              .isNotNull()
              .isEmpty();
          final ops = await pendingOps(created.id);
          check(completionOf(ops).chatSettings!.params).isEmpty();
          check(completionOf(ops).chatSettings!.baseline!.systemMessage)
              .isNull();
        },
      );

      test(
        'a new chat starts with the draft settings in its first stored blob',
        () async {
          final api = _GatedCompletionApi(Completer<void>()..complete());
          final container = _container(
            db: db,
            active: null,
            messages: const [],
            api: api,
            syncEngine: _NoDrainSyncEngine(db, api),
          );
          addTearDown(container.dispose);
          container.read(pendingOpenWebUiChatSettingsProvider.notifier).replace(
            {'system': 'Draft prompt', 'stop': 'a,b'},
          );

          await durableSend(container, 'first turn', null);

          final created = container.read(activeConversationProvider)!;
          check(created.id).startsWith('local:');
          check(created.chatParams)
              .deepEquals({'system': 'Draft prompt', 'stop': 'a,b'});
          check(await db.chatsDao.getChatParams(created.id))
              .isNotNull()
              .deepEquals({'system': 'Draft prompt', 'stop': 'a,b'});
          final ops = await pendingOps(created.id);
          check(ops.map((op) => op.kind).toList())
              .deepEquals(['createChat', 'requestCompletion']);
          check(completionOf(ops).chatSettings!.params)
              .deepEquals({'system': 'Draft prompt', 'stop': 'a,b'});
          check(container.read(pendingOpenWebUiChatSettingsProvider)).isEmpty();
        },
      );

      group('a folder project\'s context stays the server\'s to apply', () {
        const folderPrompt = 'Answer as the project librarian';
        const projectFile = {
          'type': 'collection',
          'id': 'kb-project',
          'name': 'Project docs',
        };

        setUp(() async {
          await db.foldersDao.replaceServerFolders([
            {
              'id': 'f-1',
              'name': 'Project',
              'created_at': 1,
              'updated_at': 2,
              'data': {
                'system_prompt': folderPrompt,
                'files': [projectFile],
                'model_ids': ['model-1'],
              },
            },
          ]);
        });

        test('a new chat started in the folder is stored in it', () async {
          final api = _WireCompletionApi();
          final container = _container(
            db: db,
            active: null,
            messages: const [],
            api: api,
            syncEngine: _NoDrainSyncEngine(db, api),
          );
          addTearDown(container.dispose);
          container.read(pendingFolderIdProvider.notifier).set('f-1');

          await durableSend(
            container,
            'first turn',
            null,
            pendingFolderIdOverride: 'f-1',
          );

          final created = container.read(activeConversationProvider)!;
          check(created.folderId).equals('f-1');
          check((await db.chatsDao.getChat(created.id))!.folderId)
              .equals('f-1');
          final ops = await pendingOps(created.id);
          check(ops.map((op) => op.kind).toList())
              .deepEquals(['createChat', 'requestCompletion']);
          // The folder id is what the server resolves the project from; the
          // queued turn does not carry the project's own content.
          final queued = ops.map((op) => op.payload).join();
          check(queued).not((it) => it.contains(folderPrompt));
          check(queued).not((it) => it.contains('kb-project'));
          // The chat now owns the folder id, so the draft's pending one is
          // spent and cannot place a later chat in the folder.
          check(container.read(pendingFolderIdProvider)).isNull();
        });

        test(
          'the completion for a chat in it repeats none of the project',
          () async {
            await _seedChat(db, chatId);
            await (db.update(db.chats)..where((t) => t.id.equals(chatId)))
                .write(const ChatsCompanion(folderId: Value('f-1')));
            final api = _WireCompletionApi();
            final messages = <ChatMessage>[_user('u0', 'earlier')];
            final container = _container(
              db: db,
              active: _conversation(
                chatId,
                messages,
                ChatStorageKind.openWebUi,
              ).copyWith(folderId: 'f-1'),
              messages: messages,
              api: api,
              syncEngine: _NoDrainSyncEngine(db, api),
            );
            addTearDown(container.dispose);

            await durableSend(container, 'queued turn', null);
            final op = (await pendingOps(chatId))
                .singleWhere((op) => op.kind == 'requestCompletion');
            await container
                .read(
                  Provider<RequestCompletionRunner>(
                    (ref) => ChatRequestCompletionRunner(ref),
                  ),
                )
                .run(
                  chatId: chatId,
                  payload: jsonDecode(op.payload) as Map<String, dynamic>,
                );

            check(api.completionBodies).length.equals(1);
            final wire = jsonEncode(api.sentBody);
            check(wire).not((it) => it.contains(folderPrompt));
            check(wire).not((it) => it.contains('kb-project'));
            check(api.sentBody.containsKey('files')).isFalse();
            check(api.sentSystem).isNull();
          },
        );
      });
    });
  });

  group('the code interpreter reaches every Open WebUI request path', () {
    const chatId = 'interpreter-chat';
    const assistantId = 'interpreter-assistant';

    /// A signed-in member of a server that runs the interpreter on Jupyter,
    /// with the interpreter chosen in the composer. [terminalId] and [model]
    /// are what the composer has selected when the turn is sent.
    Future<({_WireCompletionApi api, ProviderContainer container})> open({
      required List<ChatMessage> messages,
      String? chatIdOnScreen = chatId,
      Model model = const Model(id: 'model-1', name: 'Model 1'),
      String? terminalId,
      bool selected = true,
      bool switchableAccount = false,
      bool keepAuthInterceptor = false,
      void Function(_WireCompletionApi api)? serve,
    }) async {
      final api = _WireCompletionApi(keepAuthInterceptor: keepAuthInterceptor)
        ..modelsBody = <String, dynamic>{
          'data': <Map<String, dynamic>>[
            // No capability entry: capable, as Open WebUI treats it.
            <String, dynamic>{'id': 'model-1', 'name': 'Model 1'},
            <String, dynamic>{'id': 'other-model', 'name': 'Other model'},
          ],
        };
      serve?.call(api);
      final container = _container(
        db: db,
        active: chatIdOnScreen == null
            ? null
            : _conversation(
                chatIdOnScreen,
                messages,
                ChatStorageKind.openWebUi,
              ),
        messages: messages,
        api: api,
        syncEngine: _PersistingSyncEngine(db, api),
        model: model,
        terminalId: terminalId,
        extraOverrides: [
          isOnlineProvider.overrideWithValue(true),
          if (switchableAccount) ...[
            currentUserProvider2.overrideWith(
              (ref) => ref.watch(_switchableAccountProvider),
            ),
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(_signInEpochProvider),
            ),
          ] else ...[
            currentUserProvider2.overrideWithValue(_accountA),
            openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
          ],
          isAuthenticatedProvider2.overrideWithValue(true),
          backendConfigProvider.overrideWith(() => _FetchedConfig(api)),
          openWebUiUserSettingsCacheProvider.overrideWithValue(
            OpenWebUiUserSettingsCache(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(backendConfigProvider.future);
      await container.read(userPermissionsProvider.future);
      if (selected) {
        container.read(codeInterpreterEnabledProvider.notifier).set(true);
      }
      return (api: api, container: container);
    }

    Map<String, dynamic> featuresOf(_WireCompletionApi api) =>
        api.sentBody['features'] as Map<String, dynamic>;

    Future<void> replay(
      ProviderContainer container,
      RequestCompletionPayload payload,
    ) => container
        .read(
          Provider<RequestCompletionRunner>(
            (ref) => ChatRequestCompletionRunner(ref),
          ),
        )
        .run(chatId: chatId, payload: payload.toJson());

    Future<OutboxOp> queuedOp(String id) async =>
        (await db.outboxDao.pendingForChat(id))
            .singleWhere((op) => op.kind == 'requestCompletion');

    test('a normal send carries it', () async {
      await _seedChat(db, chatId);
      final messages = <ChatMessage>[_user('u0', 'earlier')];
      final session = await open(messages: messages);

      await sendMessageWithContainer(session.container, 'plot this', null);

      check(featuresOf(session.api)['code_interpreter']).equals(true);
    });

    test('a send without the choice says it is off', () async {
      await _seedChat(db, chatId);
      final messages = <ChatMessage>[_user('u0', 'earlier')];
      final session = await open(messages: messages, selected: false);

      await sendMessageWithContainer(session.container, 'plot this', null);

      check(featuresOf(session.api)['code_interpreter']).equals(false);
    });

    test('a regeneration carries it', () async {
      await _seedChat(db, chatId);
      final messages = <ChatMessage>[
        _user('u1', 'question'),
        ChatMessage(
          id: 'a1',
          role: 'assistant',
          content: 'first answer',
          timestamp: DateTime.utc(2026, 7, 13, 0, 0, 1),
          model: 'model-1',
        ),
      ];
      final session = await open(messages: messages);

      await regenerateMessage(session.container, 'question', null);

      check(session.api.completionBodies).length.equals(1);
      check(featuresOf(session.api)['code_interpreter']).equals(true);
    });

    test(
      'a durable send admits it, and the replay sends what was admitted',
      () async {
        await _seedChat(db, chatId);
        final messages = <ChatMessage>[_user('u0', 'earlier')];
        final session = await open(messages: messages);
        // Hold the drain so the admission can be read as written.
        final held = _container(
          db: db,
          active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
          messages: messages,
          api: session.api,
          syncEngine: _NoDrainSyncEngine(db, session.api),
          extraOverrides: [
            isOnlineProvider.overrideWithValue(true),
            currentUserProvider2.overrideWithValue(_accountA),
            isAuthenticatedProvider2.overrideWithValue(true),
            openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
            backendConfigProvider.overrideWith(
              () => _FetchedConfig(session.api),
            ),
            openWebUiUserSettingsCacheProvider.overrideWithValue(
              OpenWebUiUserSettingsCache(),
            ),
          ],
        );
        addTearDown(held.dispose);
        await held.read(backendConfigProvider.future);
        await held.read(userPermissionsProvider.future);
        held.read(codeInterpreterEnabledProvider.notifier).set(true);

        await durableSend(held, 'queued turn', null);

        final op = await queuedOp(chatId);
        check(
          RequestCompletionPayload.fromJson(
            jsonDecode(op.payload) as Map<String, dynamic>,
          ).enableCodeInterpreter,
        ).isTrue();

        // The composer changes after the turn was admitted: it is off, and the
        // model on screen is another one.
        held.read(codeInterpreterEnabledProvider.notifier).set(false);
        await replay(
          held,
          RequestCompletionPayload.fromJson(
            jsonDecode(op.payload) as Map<String, dynamic>,
          ),
        );

        check(featuresOf(session.api)['code_interpreter']).equals(true);
      },
    );

    test(
      'a durable send admits none for a turn that did not choose it',
      () async {
        await _seedChat(db, chatId);
        final messages = <ChatMessage>[_user('u0', 'earlier')];
        final session = await open(messages: messages, selected: false);

        await durableSend(session.container, 'queued turn', null);
        await pumpEventQueue();

        final payload = jsonDecode(
          (await db.outboxDao.pendingForChat(chatId))
              .singleWhere((op) => op.kind == 'requestCompletion')
              .payload,
        ) as Map<String, dynamic>;
        check(payload.containsKey('enableCodeInterpreter')).isFalse();
      },
    );

    for (final foreground in [true, false]) {
      final path = foreground ? 'live' : 'headless';

      test('a $path replay of an admitted turn carries it', () async {
        await _seedChat(db, chatId, assistantId: assistantId);
        final messages = foreground
            ? <ChatMessage>[
                _user('u0', 'hello'),
                _streamingAssistant(assistantId, ''),
              ]
            : <ChatMessage>[_user('elsewhere', 'a different chat')];
        final session = await open(
          messages: messages,
          chatIdOnScreen: foreground ? chatId : 'foreground-chat',
          selected: false,
        );

        await replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        );

        check(session.api.completionBodies).length.equals(1);
        check(featuresOf(session.api)['code_interpreter']).equals(true);
      });

      test('a $path replay of an older op never gains it', () async {
        await _seedChat(db, chatId, assistantId: assistantId);
        final messages = foreground
            ? <ChatMessage>[
                _user('u0', 'hello'),
                _streamingAssistant(assistantId, ''),
              ]
            : <ChatMessage>[_user('elsewhere', 'a different chat')];
        // The composer has it on now; the op was queued before it existed.
        final session = await open(
          messages: messages,
          chatIdOnScreen: foreground ? chatId : 'foreground-chat',
        );
        final askedBeforeReplay = session.api.paths.length;

        await replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
          ),
        );

        check(featuresOf(session.api)['code_interpreter']).equals(false);
        check(
          session.api.paths.skip(askedBeforeReplay),
        ).not((paths) => paths.contains('/api/config'));
      });

      test('a $path replay is not sent, and says why, when the server moved to '
          'its browser engine', () async {
        await _seedChat(db, chatId, assistantId: assistantId);
        final messages = foreground
            ? <ChatMessage>[
                _user('u0', 'hello'),
                _streamingAssistant(assistantId, ''),
              ]
            : <ChatMessage>[_user('elsewhere', 'a different chat')];
        final session = await open(
          messages: messages,
          chatIdOnScreen: foreground ? chatId : 'foreground-chat',
        );
        session.api.configBody = _interpreterConfig(engine: 'pyodide');

        await expectLater(
          replay(
            session.container,
            const RequestCompletionPayload(
              assistantMessageId: assistantId,
              model: 'model-1',
              enableCodeInterpreter: true,
            ),
          ),
          throwsA(isA<SyncTerminalException>()),
        );

        check(session.api.completionBodies).isEmpty();
        final row = (await db.messagesDao.getMessage(chatId, assistantId))!;
        final payload = jsonDecode(row.payload) as Map<String, dynamic>;
        check(payload['isStreaming']).equals(false);
        check((payload['error'] as Map)['content'] as String)
            .contains('runs code in the browser');
        if (foreground) {
          final shown = session.container
              .read(chatMessagesProvider)
              .singleWhere((message) => message.id == assistantId);
          check(shown.isStreaming).isFalse();
          check(shown.error?.content)
              .isNotNull()
              .contains('runs code in the browser');
        }
      });
    }

    for (final foreground in [true, false]) {
      final path = foreground ? 'live' : 'headless';

      test('a $path turn refused for the interpreter is sent, once, when the '
          'server supports it again', () async {
        await _seedChat(db, chatId, assistantId: assistantId);
        final messages = foreground
            ? <ChatMessage>[
                _user('u0', 'hello'),
                _streamingAssistant(assistantId, ''),
              ]
            : <ChatMessage>[_user('elsewhere', 'a different chat')];
        final session = await open(
          messages: messages,
          chatIdOnScreen: foreground ? chatId : 'foreground-chat',
        );
        const payload = RequestCompletionPayload(
          assistantMessageId: assistantId,
          model: 'model-1',
          enableCodeInterpreter: true,
        );
        session.api.configBody = _interpreterConfig(engine: 'pyodide');

        // Retrying while the server still cannot run it refuses again.
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            replay(session.container, payload),
            throwsA(isA<SyncTerminalException>()),
          );
        }
        check(session.api.completionBodies).isEmpty();
        final refused = (await db.messagesDao.getMessage(
          chatId,
          assistantId,
        ))!;
        check((jsonDecode(refused.payload) as Map<String, dynamic>)['error'])
            .isNotNull();

        // The turn was never sent, so the retry sends it as it was admitted:
        // with the interpreter, not without.
        session.api.configBody = _interpreterConfig(engine: 'jupyter');
        await replay(session.container, payload);
        check(session.api.completionBodies).length.equals(1);
        check(featuresOf(session.api)['code_interpreter']).equals(true);

        // Once sent, the turn is fenced against a second submission.
        await replay(session.container, payload);
        check(session.api.completionBodies).length.equals(1);
      });
    }

    // The refusal marker can stay on the row after the retry; it must never
    // reopen a turn that was sent afterwards.
    final sentAfterRefusal = <String, Future<void> Function()>{
      'was sent and completed': () => db.messagesDao.markAssistantResponseDone(
        chatId: chatId,
        messageId: assistantId,
      ),
      'was sent and could not be recovered': () =>
          db.messagesDao.markAssistantCompletionRecoveryFailed(
            chatId: chatId,
            messageId: assistantId,
            error: 'recovery failed',
          ),
    };

    for (final MapEntry(:key, :value) in sentAfterRefusal.entries) {
      test('a turn that was refused, then $key, is not sent again', () async {
        await _seedChat(db, chatId, assistantId: assistantId);
        await db.messagesDao.markAssistantCompletionRefused(
          chatId: chatId,
          messageId: assistantId,
          error: 'refused',
        );
        await value();
        final session = await open(
          messages: <ChatMessage>[_user('elsewhere', 'a different chat')],
          chatIdOnScreen: 'foreground-chat',
        );

        await replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        );

        check(session.api.completionBodies).isEmpty();
      });
    }

    test('a refused turn that is retried under another account is not sent '
        'and is not lost', () async {
      await _seedChat(db, chatId, assistantId: assistantId);
      final session = await open(
        messages: <ChatMessage>[_user('elsewhere', 'a different chat')],
        chatIdOnScreen: 'foreground-chat',
        switchableAccount: true,
      );
      const payload = RequestCompletionPayload(
        assistantMessageId: assistantId,
        model: 'model-1',
        enableCodeInterpreter: true,
      );
      session.api.configBody = _interpreterConfig(engine: 'pyodide');
      await expectLater(
        replay(session.container, payload),
        throwsA(isA<SyncTerminalException>()),
      );

      // Support returns, but account B signs in while the retry is reading it.
      session.api.configBody = _interpreterConfig(engine: 'jupyter');
      session.api.duringConfig = () {
        session.container.read(_switchableAccountProvider.notifier).switchToB();
        session.container.read(_signInEpochProvider.notifier).rotate();
      };
      final askedBeforeRetry = session.api.paths.length;
      await expectLater(
        replay(session.container, payload),
        throwsA(isA<OutboxDeferralException>()),
      );
      check(session.api.paths.skip(askedBeforeRetry))
        ..not((paths) => paths.contains('/api/v1/users/permissions'))
        ..not((paths) => paths.contains('/api/models'));
      check(session.api.completionBodies).isEmpty();
    });

    for (final foreground in [true, false]) {
      final path = foreground ? 'live' : 'headless';

      test('a $path replay is judged on the turn\'s own model, never the one '
          'on screen', () async {
        await _seedChat(db, chatId, assistantId: assistantId);
        final messages = foreground
            ? <ChatMessage>[
                _user('u0', 'hello'),
                _streamingAssistant(assistantId, ''),
              ]
            : <ChatMessage>[_user('elsewhere', 'a different chat')];
        // The composer has moved on to a model that allows the interpreter;
        // the server turns it off for the model the turn was queued with.
        final session = await open(
          messages: messages,
          chatIdOnScreen: foreground ? chatId : 'foreground-chat',
          selected: false,
          model: const Model(id: 'other-model', name: 'Other model'),
          serve: (api) => api.modelsBody = <String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'model-1',
                'name': 'Model 1',
                'info': <String, dynamic>{
                  'meta': <String, dynamic>{
                    'capabilities': <String, dynamic>{
                      'code_interpreter': false,
                    },
                  },
                },
              },
              <String, dynamic>{
                'id': 'other-model',
                'name': 'Other model',
                'info': <String, dynamic>{
                  'meta': <String, dynamic>{
                    'capabilities': <String, dynamic>{
                      'code_interpreter': true,
                    },
                  },
                },
              },
            ],
          },
        );

        await expectLater(
          replay(
            session.container,
            const RequestCompletionPayload(
              assistantMessageId: assistantId,
              model: 'model-1',
              enableCodeInterpreter: true,
            ),
          ),
          throwsA(isA<SyncTerminalException>()),
        );

        check(session.api.completionBodies).isEmpty();
      });

      test('a $path replay is sent when its own model allows it, whatever the '
          'model on screen does', () async {
        await _seedChat(db, chatId, assistantId: assistantId);
        final messages = foreground
            ? <ChatMessage>[
                _user('u0', 'hello'),
                _streamingAssistant(assistantId, ''),
              ]
            : <ChatMessage>[_user('elsewhere', 'a different chat')];
        const withoutInterpreter = <String, dynamic>{
          'info': <String, dynamic>{
            'meta': <String, dynamic>{
              'capabilities': <String, dynamic>{'code_interpreter': false},
            },
          },
        };
        final session = await open(
          messages: messages,
          chatIdOnScreen: foreground ? chatId : 'foreground-chat',
          selected: false,
          model: const Model(
            id: 'other-model',
            name: 'Other model',
            metadata: withoutInterpreter,
          ),
          serve: (api) => api.modelsBody = <String, dynamic>{
            'data': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'model-1', 'name': 'Model 1'},
              <String, dynamic>{
                'id': 'other-model',
                'name': 'Other model',
                ...withoutInterpreter,
              },
            ],
          },
        );

        await replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        );

        check(featuresOf(session.api)['code_interpreter']).equals(true);
      });
    }

    test('a replay is not sent when the server does not list its model', () async {
      await _seedChat(db, chatId, assistantId: assistantId);
      final session = await open(
        messages: <ChatMessage>[_user('elsewhere', 'a different chat')],
        chatIdOnScreen: 'foreground-chat',
        // The model on screen is listed and capable; the queued one is not
        // listed, so nothing says whether it can run the interpreter.
        model: const Model(id: 'other-model', name: 'Other model'),
        serve: (api) => api.modelsBody = <String, dynamic>{
          'data': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'other-model', 'name': 'Other model'},
          ],
        },
      );

      await expectLater(
        replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        ),
        throwsA(isA<SyncTerminalException>()),
      );

      check(session.api.completionBodies).isEmpty();
    });

    test('a replay whose model list cannot be read retries', () async {
      await _seedChat(db, chatId, assistantId: assistantId);
      final session = await open(
        messages: <ChatMessage>[_user('elsewhere', 'a different chat')],
        chatIdOnScreen: 'foreground-chat',
        serve: (api) => api.modelsBody = null,
      );

      await expectLater(
        replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        ),
        throwsA(isA<CodeInterpreterRecheckFailed>()),
      );

      check(session.api.completionBodies).isEmpty();
    });

    test('a replay reads nothing more once another account has signed in', () async {
      await _seedChat(db, chatId, assistantId: assistantId);
      final session = await open(
        messages: <ChatMessage>[_user('elsewhere', 'a different chat')],
        chatIdOnScreen: 'foreground-chat',
        switchableAccount: true,
      );
      // Account B signs in on the same server, API and database while the
      // config is being read. The token is unchanged here, so only the
      // ownership check can stop the next read.
      session.api.duringConfig = () {
        session.container.read(_switchableAccountProvider.notifier).switchToB();
        session.container.read(_signInEpochProvider.notifier).rotate();
      };
      final askedBeforeReplay = session.api.paths.length;

      await expectLater(
        replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        ),
        throwsA(isA<OutboxDeferralException>()),
      );

      check(session.api.paths.skip(askedBeforeReplay))
        ..not((paths) => paths.contains('/api/v1/users/permissions'))
        ..not((paths) => paths.contains('/api/models'));
      check(session.api.completionBodies).isEmpty();
    });

    test('a replay never reads under the token of an account that replaced '
        'its own', () async {
      await _seedChat(db, chatId, assistantId: assistantId);
      final session = await open(
        messages: <ChatMessage>[_user('elsewhere', 'a different chat')],
        chatIdOnScreen: 'foreground-chat',
        keepAuthInterceptor: true,
        serve: (api) => api.updateAuthToken('account-a-token'),
      );
      // The session's token changes while the config is being read, before
      // anything else could notice, so only the request itself can refuse.
      session.api.duringConfig = () =>
          session.api.updateAuthToken('account-b-token');
      session.api.credentials.clear();

      await expectLater(
        replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        ),
        throwsA(isA<CodeInterpreterRecheckFailed>()),
      );

      check(
        session.api.credentials.where(
          (request) => request.authorization == 'Bearer account-b-token',
        ),
      ).isEmpty();
      check(session.api.completionBodies).isEmpty();
    });

    test('a replay stops, rather than runs without it, once the account may not use it', () async {
      await _seedChat(db, chatId, assistantId: assistantId);
      final messages = <ChatMessage>[_user('elsewhere', 'a different chat')];
      final session = await open(
        messages: messages,
        chatIdOnScreen: 'foreground-chat',
      );
      session.api.permissionsBody = _interpreterPermissions(allowed: false);

      await expectLater(
        replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        ),
        throwsA(isA<SyncTerminalException>()),
      );

      check(session.api.completionBodies).isEmpty();
    });

    test('a replay that cannot reach the server retries instead of dropping the turn', () async {
      await _seedChat(db, chatId, assistantId: assistantId);
      final messages = <ChatMessage>[_user('elsewhere', 'a different chat')];
      final session = await open(
        messages: messages,
        chatIdOnScreen: 'foreground-chat',
      );
      session.api.configFails = true;

      await expectLater(
        replay(
          session.container,
          const RequestCompletionPayload(
            assistantMessageId: assistantId,
            model: 'model-1',
            enableCodeInterpreter: true,
          ),
        ),
        throwsA(isA<CodeInterpreterRecheckFailed>()),
      );

      check(session.api.completionBodies).isEmpty();
      final row = (await db.messagesDao.getMessage(chatId, assistantId))!;
      check((jsonDecode(row.payload) as Map<String, dynamic>)['isStreaming'])
          .equals(true);
    });

    // The choice was made while the server allowed it. Each case is a change
    // on the server before the next send.
    final changedAfterChoice = <String, void Function(_WireCompletionApi api)>{
      'the server moves to its browser engine': (api) =>
          api.configBody = _interpreterConfig(engine: 'pyodide'),
      'the administrator switches the interpreter off': (api) =>
          api.configBody = _interpreterConfig(enabled: false),
      'the account loses the permission': (api) =>
          api.permissionsBody = _interpreterPermissions(allowed: false),
    };

    for (final MapEntry(:key, :value) in changedAfterChoice.entries) {
      test('a send is not made with it once $key', () async {
        await _seedChat(db, chatId);
        final messages = <ChatMessage>[_user('u0', 'earlier')];
        final session = await open(messages: messages);
        check(session.container.read(codeInterpreterEnabledProvider)).isTrue();

        value(session.api);
        session.container
          ..invalidate(backendConfigProvider)
          ..invalidate(userPermissionsProvider);
        await session.container.read(backendConfigProvider.future);
        await session.container.read(userPermissionsProvider.future);
        await sendMessageWithContainer(session.container, 'plot this', null);

        check(featuresOf(session.api)['code_interpreter']).equals(false);
      });
    }

    test(
      'a terminal selected for the turn leaves the interpreter out',
      () async {
        await _seedChat(db, chatId);
        final messages = <ChatMessage>[_user('u0', 'earlier')];
        // The choice was made before the terminal was selected, which the real
        // selection would have ended; the request must not depend on that.
        final session = await open(messages: messages);
        final withTerminal = _container(
          db: db,
          active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
          messages: messages,
          api: session.api,
          syncEngine: _PersistingSyncEngine(db, session.api),
          terminalId: 'terminal-1',
          extraOverrides: [
            currentUserProvider2.overrideWithValue(_accountA),
            isAuthenticatedProvider2.overrideWithValue(true),
            openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
            backendConfigProvider.overrideWith(
              () => _FetchedConfig(session.api),
            ),
            codeInterpreterEnabledProvider.overrideWith(_AlwaysSelected.new),
          ],
        );
        addTearDown(withTerminal.dispose);
        await withTerminal.read(backendConfigProvider.future);
        await withTerminal.read(userPermissionsProvider.future);

        await sendMessageWithContainer(withTerminal, 'run it', null);

        check(featuresOf(session.api)['code_interpreter']).equals(false);
        check(session.api.sentBody['terminal_id']).equals('terminal-1');
      },
    );

    test('a model that turns it off is sent without it', () async {
      await _seedChat(db, chatId);
      final messages = <ChatMessage>[_user('u0', 'earlier')];
      final session = await open(
        messages: messages,
        model: const Model(id: 'model-1', name: 'Model 1'),
      );
      final capable = session.container;
      check(capable.read(codeInterpreterBlockProvider)).isNull();

      final off = _container(
        db: db,
        active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
        messages: messages,
        api: session.api,
        syncEngine: _PersistingSyncEngine(db, session.api),
        model: const Model(
          id: 'model-1',
          name: 'Model 1',
          metadata: {
            'info': {
              'meta': {
                'capabilities': {'code_interpreter': false},
              },
            },
          },
        ),
        extraOverrides: [
          currentUserProvider2.overrideWithValue(_accountA),
          isAuthenticatedProvider2.overrideWithValue(true),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
          backendConfigProvider.overrideWith(() => _FetchedConfig(session.api)),
          codeInterpreterEnabledProvider.overrideWith(_AlwaysSelected.new),
        ],
      );
      addTearDown(off.dispose);
      await off.read(backendConfigProvider.future);
      await off.read(userPermissionsProvider.future);

      await sendMessageWithContainer(off, 'run it', null);

      check(featuresOf(session.api)['code_interpreter']).equals(false);
    });
  });

  group('merging the answers of a comparison', () {
    const chatId = 'merge-chat';
    const userId = 'merge-user';
    const firstId = 'merge-answer-0';
    const secondId = 'merge-answer-1';

    Map<String, dynamic> answerPayload(
      String id,
      int slot,
      String content, {
      Map<String, dynamic> extra = const {},
    }) => <String, dynamic>{
      'id': id,
      'parentId': userId,
      'childrenIds': <String>[],
      'role': 'assistant',
      'content': content,
      'model': 'model-1',
      'modelName': 'Model 1',
      'modelIdx': slot,
      'timestamp': 2,
      'done': true,
      ...extra,
    };

    Future<void> seedTurn({
      Map<String, dynamic>? firstMerged,
      Map<String, dynamic>? shownMerged,
      String? storedOwner,
    }) async {
      await _seedChat(db, chatId);
      if (storedOwner != null) {
        await (db.update(db.chats)..where((chat) => chat.id.equals(chatId)))
            .write(ChatsCompanion(userId: Value(storedOwner)));
      }
      Future<void> insert(
        String id,
        String role,
        String content,
        Map<String, dynamic> payload, {
        String? parent,
      }) => db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              chatId: chatId,
              role: role,
              parentId: Value(parent),
              content: content,
              model: role == 'assistant' ? const Value('model-1') : const Value.absent(),
              createdAt: 1,
              orderIndex: id == userId ? 0 : (id == firstId ? 1 : 2),
              payload: jsonEncode(payload),
            ),
          );
      await insert(userId, 'user', 'Name a prime number.', <String, dynamic>{
        'id': userId,
        'parentId': null,
        'childrenIds': [firstId, secondId],
        'role': 'user',
        'content': 'Name a prime number.',
        'models': ['model-1', 'model-1'],
        'timestamp': 1,
      });
      await insert(
        firstId,
        'assistant',
        '13 is prime.',
        answerPayload(
          firstId,
          0,
          '13 is prime.',
          extra: {
            'x_future_key': {'keep': true},
            'merged': ?firstMerged,
          },
        ),
        parent: userId,
      );
      await insert(
        secondId,
        'assistant',
        '17 is prime.',
        answerPayload(
          secondId,
          1,
          '17 is prime.',
          extra: {'merged': ?shownMerged},
        ),
        parent: userId,
      );
    }

    /// The transcript as a saved comparison opens: the second answer shown,
    /// the first held beside it as a stored alternative.
    Future<({_FanOutApi api, ProviderContainer container})> open({
      Map<String, dynamic>? firstMerged,
      Map<String, dynamic>? shownMerged,
      User? signedInAs,
      String? cachedOwner,
      String? storedOwner,
    }) async {
      await seedTurn(
        firstMerged: firstMerged,
        shownMerged: shownMerged,
        storedOwner: storedOwner,
      );
      final api = _FanOutApi();
      final shown = ChatMessage(
        id: secondId,
        role: 'assistant',
        content: '17 is prime.',
        timestamp: DateTime.utc(2026, 7, 13),
        model: 'model-1',
        metadata: {
          'parentId': userId,
          'modelIdx': 1,
          'merged': ?shownMerged,
        },
        versions: [
          ChatMessageVersion(
            id: firstId,
            content: '13 is prime.',
            timestamp: DateTime.utc(2026, 7, 13),
            model: 'model-1',
            modelIdx: 0,
            merged: firstMerged,
          ),
        ],
      );
      final messages = <ChatMessage>[
        ChatMessage(
          id: userId,
          role: 'user',
          content: 'Name a prime number.',
          timestamp: DateTime.utc(2026, 7, 13),
        ),
        shown,
      ];
      final container = _container(
        db: db,
        active: _conversation(
          chatId,
          messages,
          ChatStorageKind.openWebUi,
        ).copyWith(userId: cachedOwner),
        messages: messages,
        api: api,
        syncEngine: _QuietSyncEngine(db, api),
        extraOverrides: [
          openWebUiAuthSessionEpochProvider.overrideWith(
            (ref) => ref.watch(_signInEpochProvider),
          ),
          if (signedInAs != null) ..._signedInAs(signedInAs),
        ],
      );
      addTearDown(container.dispose);
      return (api: api, container: container);
    }

    Future<Map<String, dynamic>> storedPayload(String id) async =>
        jsonDecode((await db.messagesDao.getMessage(chatId, id))!.payload)
            as Map<String, dynamic>;

    Future<void> startMerge(
      ProviderContainer container, {
      required Completer<Object?> outcome,
      String target = secondId,
    }) {
      return container
          .read(comparisonMergeProvider.notifier)
          .merge(
            targetMessageId: target,
            displayedMessageId: secondId,
            parentMessageId: userId,
            model: 'model-1',
            responses: const ['13 is prime.', '17 is prime.'],
          )
          .then(
            (_) => outcome.complete(null),
            onError: (Object error) => outcome.complete(error),
          );
    }

    ChatMessage shownAnswer(ProviderContainer container) => container
        .read(chatMessagesProvider)
        .firstWhere((message) => message.id == secondId);

    test('streams into the chosen answer, then saves it in Open WebUI\'s own '
        'field and leaves every original byte for byte', () async {
      final (:api, :container) = await open();
      final firstBefore = (await db.messagesDao.getMessage(chatId, firstId))!
          .payload;
      final secondBefore = await storedPayload(secondId);
      final outcome = Completer<Object?>();
      unawaited(startMerge(container, outcome: outcome));
      await Future<void>.delayed(Duration.zero);

      // Exactly the request Open WebUI's own client makes.
      check(api.merges).length.equals(1);
      check(api.merges.single.model).equals('model-1');
      check(api.merges.single.prompt).equals('Name a prime number.');
      check(api.merges.single.responses).deepEquals([
        '13 is prime.',
        '17 is prime.',
      ]);
      check(container.read(comparisonMergeProvider)).equals(secondId);

      final stream = api.mergeUpdates!;
      stream.add(const OpenWebUIContentDelta('\n'));
      stream.add(const OpenWebUIContentDelta('Both '));
      await Future<void>.delayed(Duration.zero);
      check(shownAnswer(container).mergedResponse?.content).equals('Both ');
      stream.add(const OpenWebUIContentDelta('agree.'));
      stream.add(const OpenWebUIStreamDone());
      await stream.close();
      check(await outcome.future).isNull();

      // The answer itself is still its own text; the merge sits beside it.
      check(shownAnswer(container).content).equals('17 is prime.');
      check(shownAnswer(container).mergedResponse?.content).equals(
        'Both agree.',
      );
      final saved = await storedPayload(secondId);
      check(saved['merged']).isA<Map<String, dynamic>>().deepEquals({
        'status': true,
        'content': 'Both agree.',
      });
      check(saved['content']).equals('17 is prime.');
      check(saved['modelIdx']).equals(1);
      check({...saved}..remove('merged')).deepEquals(secondBefore);
      check(
        (await db.messagesDao.getMessage(chatId, firstId))!.payload,
      ).equals(firstBefore);
      check(
        (await db.outboxDao.pendingForChat(chatId)).where(
          (op) => op.kind == 'updateChat',
        ),
      ).isNotEmpty();
      check(container.read(comparisonMergeProvider)).isNull();
    });

    test('stopping keeps the text that arrived and fails no source answer', () async {
      final (:api, :container) = await open();
      final outcome = Completer<Object?>();
      unawaited(startMerge(container, outcome: outcome));
      await Future<void>.delayed(Duration.zero);
      api.mergeUpdates!.add(const OpenWebUIContentDelta('Half a merge'));
      await Future<void>.delayed(Duration.zero);

      await container.read(comparisonMergeProvider.notifier).cancel();
      check(await outcome.future).isNull();

      check((await storedPayload(secondId))['merged']).isA<Map<String, dynamic>>()
          .deepEquals({'status': true, 'content': 'Half a merge'});
      for (final id in [firstId, secondId]) {
        final payload = await storedPayload(id);
        check(payload.containsKey('error')).isFalse();
        check(payload['done']).equals(true);
      }
      check(shownAnswer(container).error).isNull();
      check(shownAnswer(container).versions.single.error).isNull();
      check(container.read(comparisonMergeProvider)).isNull();
    });

    test('a server without the endpoint is explained and never asked '
        'through a chat completion', () async {
      final (:api, :container) = await open();
      api.mergeEndpointMissing = true;
      final outcome = Completer<Object?>();
      await startMerge(container, outcome: outcome);

      final error = await outcome.future;
      check(error).isA<ComparisonMergeException>().has(
        (e) => e.reason,
        'reason',
      ).equals(ComparisonMergeFailure.unavailable);
      check(api.requests).isEmpty();
      check((await storedPayload(secondId)).containsKey('merged')).isFalse();
      check(shownAnswer(container).mergedResponse).isNull();
      check(container.read(comparisonMergeProvider)).isNull();
    });

    test('a sign-in change mid-merge writes nothing for the new account',
        () async {
      final (:api, :container) = await open();
      final outcome = Completer<Object?>();
      unawaited(startMerge(container, outcome: outcome));
      await Future<void>.delayed(Duration.zero);
      api.mergeUpdates!.add(const OpenWebUIContentDelta('Some text'));
      await Future<void>.delayed(Duration.zero);

      container.read(_signInEpochProvider.notifier).rotate();
      api.mergeUpdates!.add(const OpenWebUIContentDelta(' more'));
      await Future<void>.delayed(Duration.zero);

      check(await outcome.future).isA<ComparisonMergeException>().has(
        (e) => e.reason,
        'reason',
      ).equals(ComparisonMergeFailure.ownerChanged);
      check((await storedPayload(secondId)).containsKey('merged')).isFalse();
      check(
        (await db.outboxDao.pendingForChat(chatId)).where(
          (op) => op.kind == 'updateChat',
        ),
      ).isEmpty();
    });

    test('answers with no text yet cannot be merged', () async {
      final (:api, :container) = await open();
      await check(
        container
            .read(comparisonMergeProvider.notifier)
            .merge(
              targetMessageId: secondId,
              displayedMessageId: secondId,
              parentMessageId: userId,
              model: 'model-1',
              responses: const ['13 is prime.', '  '],
            ),
      ).throws<ComparisonMergeException>();
      check(api.merges).isEmpty();
    });

    const shownMerge = {'status': true, 'content': 'Old merge of the shown'};
    const firstMerge = {'status': true, 'content': 'Old merge of the first'};

    Future<Iterable<OutboxOp>> queuedUpdates() async => (await db.outboxDao
            .pendingForChat(chatId))
        .where((op) => op.kind == 'updateChat');

    test('stopping while the server is still answering stops that response '
        'unread and keeps what the answer showed before', () async {
      final (:api, :container) = await open(shownMerged: shownMerge);
      final before = await storedPayload(secondId);
      api.holdMergeHeaders = Completer<void>();
      final outcome = Completer<Object?>();
      unawaited(startMerge(container, outcome: outcome));
      await api.mergeEntered.future;

      await container.read(comparisonMergeProvider.notifier).cancel();
      api.holdMergeHeaders!.complete();
      await Future<void>.delayed(Duration.zero);

      // The response that arrived after Stop is stopped without being read.
      check(api.mergeCancels).equals(1);
      check(await outcome.future).isNull();
      check(shownAnswer(container).mergedResponse?.content)
          .equals('Old merge of the shown');
      check(await storedPayload(secondId)).deepEquals(before);
      check(await queuedUpdates()).isEmpty();
      check(container.read(comparisonMergeProvider)).isNull();
    });

    test('a sign-in change while the server is still answering stops that '
        'response unread', () async {
      final (:api, :container) = await open();
      final before = await storedPayload(secondId);
      api.holdMergeHeaders = Completer<void>();
      final outcome = Completer<Object?>();
      unawaited(startMerge(container, outcome: outcome));
      await api.mergeEntered.future;

      container.read(_signInEpochProvider.notifier).rotate();
      api.holdMergeHeaders!.complete();
      await Future<void>.delayed(Duration.zero);

      check(api.mergeCancels).equals(1);
      check(await outcome.future).isA<ComparisonMergeException>().has(
        (e) => e.reason,
        'reason',
      ).equals(ComparisonMergeFailure.ownerChanged);
      check(await storedPayload(secondId)).deepEquals(before);
      check(await queuedUpdates()).isEmpty();
    });

    for (final (name, target) in [
      ('the answer being shown', secondId),
      ('a stored alternative of it', firstId),
    ]) {
      test('a replacement that fails before any text leaves the merge it '
          'replaced: $name', () async {
        final (:api, :container) = await open(
          firstMerged: firstMerge,
          shownMerged: shownMerge,
        );
        final storedBefore = [
          await storedPayload(firstId),
          await storedPayload(secondId),
        ];
        api.mergeFailure = const MoaCompletionFailed(500, 'boom');
        final outcome = Completer<Object?>();
        await startMerge(container, outcome: outcome, target: target);

        check(await outcome.future).isA<ComparisonMergeException>().has(
          (e) => e.reason,
          'reason',
        ).equals(ComparisonMergeFailure.failed);
        // Both merges are back on screen exactly as they were, and untouched
        // in the database; no source answer failed.
        check(shownAnswer(container).mergedResponse?.content)
            .equals('Old merge of the shown');
        check(shownAnswer(container).versions.single.merged)
            .isNotNull()
            .deepEquals(firstMerge);
        check(shownAnswer(container).error).isNull();
        check(await storedPayload(firstId)).deepEquals(storedBefore[0]);
        check(await storedPayload(secondId)).deepEquals(storedBefore[1]);
        check(await queuedUpdates()).isEmpty();
      });
    }

    test('a merge with no earlier merge leaves none when it fails before any '
        'text', () async {
      final (:api, :container) = await open();
      api.mergeFailure = const MoaCompletionFailed(500, 'boom');
      final outcome = Completer<Object?>();
      await startMerge(container, outcome: outcome);

      check(await outcome.future).isA<ComparisonMergeException>();
      check(shownAnswer(container).mergedResponse).isNull();
      check(shownAnswer(container).metadata!.containsKey('merged')).isFalse();
    });

    test('a newer merge that landed while a replacement failed is not erased',
        () async {
      final (:api, :container) = await open(shownMerged: shownMerge);
      api.holdMergeHeaders = Completer<void>();
      final outcome = Completer<Object?>();
      unawaited(startMerge(container, outcome: outcome));
      await api.mergeEntered.future;

      // A pull stores another device's merge for the same answer meanwhile.
      container.read(chatMessagesProvider.notifier).updateMessageById(
        secondId,
        (message) => message.copyWith(
          metadata: {
            ...?message.metadata,
            'merged': {'status': true, 'content': 'Newer merge'},
          },
        ),
      );
      api.mergeFailure = const MoaCompletionFailed(500, 'boom');
      api.holdMergeHeaders!.complete();

      check(await outcome.future).isA<ComparisonMergeException>();
      check(shownAnswer(container).mergedResponse?.content)
          .equals('Newer merge');
    });

    for (final (name, cachedOwner, storedOwner) in [
      ('the stored chat names another owner', null, 'account-b'),
      ('the cached copy names another owner', 'account-b', null),
    ]) {
      test('another account\'s comparison is never merged: $name', () async {
        final (:api, :container) = await open(
          signedInAs: _accountA,
          cachedOwner: cachedOwner,
          storedOwner: storedOwner,
        );
        final storedBefore = [
          await storedPayload(firstId),
          await storedPayload(secondId),
        ];
        final outcome = Completer<Object?>();
        unawaited(startMerge(container, outcome: outcome));
        // A merge that was allowed to start would sit waiting for text.
        final error = await outcome.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () => 'the merge went on to wait for text',
        );

        check(error).isA<ComparisonMergeException>().has(
          (e) => e.reason,
          'reason',
        ).equals(ComparisonMergeFailure.notMergeable);
        check(api.merges).isEmpty();
        check(shownAnswer(container).mergedResponse).isNull();
        check(await storedPayload(firstId)).deepEquals(storedBefore[0]);
        check(await storedPayload(secondId)).deepEquals(storedBefore[1]);
        check(await queuedUpdates()).isEmpty();
        check(container.read(comparisonMergeProvider)).isNull();
      });
    }

    test('the signed-in owner of a comparison can merge it', () async {
      final (:api, :container) = await open(
        signedInAs: _accountA,
        cachedOwner: _accountA.id,
        storedOwner: _accountA.id,
      );
      final outcome = Completer<Object?>();
      unawaited(startMerge(container, outcome: outcome));
      await api.mergeEntered.future;
      await Future<void>.delayed(Duration.zero);
      api.mergeUpdates!.add(const OpenWebUIContentDelta('Both agree.'));
      api.mergeUpdates!.add(const OpenWebUIStreamDone());
      await api.mergeUpdates!.close();

      check(await outcome.future).isNull();
      check((await storedPayload(secondId))['merged']).isA<Map<String, dynamic>>()
          .deepEquals({'status': true, 'content': 'Both agree.'});
    });
  });

  group('a model comparison is one durable turn and one request', () {
    const chatId = 'comparison-chat';
    const duplicate = Model(id: 'model-1', name: 'Model 1', isMultimodal: true);

    RequestCompletionPayload completionOf(List<OutboxOp> ops) =>
        RequestCompletionPayload.fromJson(
          jsonDecode(
                ops.singleWhere((op) => op.kind == 'requestCompletion').payload,
              )
              as Map<String, dynamic>,
        );

    Future<({_FanOutApi api, _GroupSocket socket, ProviderContainer container})>
    open({
      List<Model> available = const [duplicate],
      Map<String, dynamic>? storedParams,
      bool socketConnected = true,
      bool trackSignIn = false,
      _QuietSyncEngine Function(AppDatabase, _FanOutApi)? engine,
      Map<String, dynamic>? storedBlob,
      User? account,
    }) async {
      if (storedBlob == null) {
        await _seedChat(db, chatId, storedParams: storedParams);
      } else {
        // A chat the way the server stores it: envelope fields, and a history
        // the blob can be rebuilt from.
        await db.chatsDao.upsertServerChat(
          rows: ChatBlobMapper.blobToRows(
            chatId: chatId,
            title: 'A',
            createdAt: 1,
            updatedAt: 1,
            blob: storedBlob,
          ),
        );
      }
      final api = _FanOutApi();
      final socket = _GroupSocket(chatId: chatId, connected: socketConnected);
      final messages = <ChatMessage>[_user('u0', 'earlier')];
      final container = _container(
        db: db,
        active: _conversation(chatId, messages, ChatStorageKind.openWebUi),
        messages: messages,
        api: api,
        syncEngine: engine?.call(db, api) ?? _QuietSyncEngine(db, api),
        socket: socket,
        extraOverrides: [
          modelsProvider.overrideWith(() => _ListedModels(available)),
          if (account != null) ..._signedInAs(account),
          if (trackSignIn)
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(_signInEpochProvider),
            ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(modelsProvider.future);
      return (api: api, socket: socket, container: container);
    }

    ChatRequestCompletionRunner runnerFor(ProviderContainer container) =>
        container.read(
          Provider<ChatRequestCompletionRunner>(
            (ref) => ChatRequestCompletionRunner(
              ref,
              recoveryAttempts: 1,
              recoveryDelay: Duration.zero,
            ),
          ),
        );

    /// The chat blob the server would be sent, rebuilt from the stored rows.
    Future<Map<String, dynamic>> rebuiltBlob(String id) async => ChatBlobMapper
        .rowsToBlob(
          chatRowsFromDb(
            (await db.chatsDao.getChat(id))!,
            await db.messagesDao.getForChat(id),
          ),
        );

    Future<void> replay(ProviderContainer container) async {
      final op = (await db.outboxDao.pendingForChat(
        chatId,
      )).singleWhere((op) => op.kind == 'requestCompletion');
      await runnerFor(container).run(
        chatId: chatId,
        payload: jsonDecode(op.payload) as Map<String, dynamic>,
      );
    }

    test('admits one user row, one placeholder per model in its column and '
        'ONE completion op', () async {
      final (:api, :socket, :container) = await open();

      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      check(handles).length.equals(2);

      final rows = await db.messagesDao.getForChat(chatId);
      final user = rows.singleWhere((row) => row.role == 'user');
      final assistants = rows.where((row) => row.role == 'assistant').toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      check(assistants.map((row) => row.id)).deepEquals([
        for (final handle in handles) handle.assistantMessageId,
      ]);
      check(assistants.map((row) => row.parentId)).every(
        (it) => it.equals(user.id),
      );
      check(
        assistants.map(
          (row) =>
              (jsonDecode(row.payload) as Map<String, dynamic>)['modelIdx'],
        ),
      ).deepEquals([0, 1]);
      final userPayload = jsonDecode(user.payload) as Map<String, dynamic>;
      check(userPayload['childrenIds']).isA<List<Object?>>().deepEquals([
        for (final handle in handles) handle.assistantMessageId,
      ]);
      check(userPayload['models']).isA<List<Object?>>().deepEquals([
        'model-1',
        'model-1',
      ]);

      final ops = await db.outboxDao.pendingForChat(chatId);
      final completions = ops.where((op) => op.kind == 'requestCompletion');
      check(completions).length.equals(1);
      final admitted = completionOf(ops);
      check(admitted.comparison).isNotNull();
      check(admitted.comparison!.isUsable).isTrue();
      check(admitted.comparison!.userMessageId).equals(user.id);
      check(
        admitted.comparison!.slots.map((slot) => slot.assistantMessageId),
      ).deepEquals([for (final handle in handles) handle.assistantMessageId]);
      check(admitted.assistantMessageId).equals(handles.first.assistantMessageId);
      // The chat opens on the first answer.
      check((await db.chatsDao.getChat(chatId))!.currentMessageId).equals(
        handles.first.assistantMessageId,
      );
      // Both placeholders are on screen, streaming, in their columns.
      final live = container.read(chatMessagesProvider);
      check(live.where((m) => m.role == 'assistant').map((m) => m.modelSlot))
          .deepEquals([0, 1]);
      check(api.requests).isEmpty();
    });

    test('replay sends ONE request that names every answer and binds each '
        'task to its own message', () async {
      final (:api, :socket, :container) = await open();
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      final ids = [for (final h in handles) h.assistantMessageId];

      await replay(container);

      check(api.requests).length.equals(1);
      final request = api.requests.single;
      check(request.responseMessageId).equals(ids.first);
      check(request.messageIds!.map((t) => t.messageId)).deepEquals(ids);
      check(request.messageIds!.map((t) => t.modelIdx)).deepEquals([0, 1]);
      check(request.messageIds!.map((t) => t.modelId)).deepEquals([
        'model-1',
        'model-1',
      ]);
      final userMessage = request.userMessage!;
      check(userMessage['childrenIds']).isA<List<Object?>>().deepEquals(ids);
      check(userMessage['models']).isA<List<Object?>>().deepEquals([
        'model-1',
        'model-1',
      ]);
      check(userMessage['parentId']).equals('u0');

      // Every answer is marked submitted, so no later run can send again.
      for (final id in ids) {
        final row = (await db.messagesDao.getMessage(chatId, id))!;
        final metadata =
            (jsonDecode(row.payload) as Map<String, dynamic>)['metadata']
                as Map<String, dynamic>;
        check(metadata['completionSubmitted']).equals(true);
      }
      // Each live answer carries the task the server started for it.
      final live = {
        for (final m in container.read(chatMessagesProvider)) m.id: m,
      };
      check(live[ids[0]]!.metadata?['taskId']).equals('task-0');
      check(live[ids[1]]!.metadata?['taskId']).equals('task-1');
    });

    test('interleaved socket updates reach only their own answer, and one '
        'answer finishing does not finish the turn', () async {
      final (:api, :socket, :container) = await open();
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      final [a, b] = [for (final h in handles) h.assistantMessageId];
      await replay(container);

      String contentOf(String id) => container
          .read(chatMessagesProvider)
          .firstWhere((message) => message.id == id)
          .content;
      bool streaming(String id) => container
          .read(chatMessagesProvider)
          .firstWhere((message) => message.id == id)
          .isStreaming;

      socket.deliver(a, 'chat:completion', {'content': 'A one'});
      socket.deliver(b, 'chat:completion', {'content': 'B one'});
      socket.deliver(a, 'chat:completion', {'content': 'A one and two'});
      check(contentOf(a)).equals('A one and two');
      check(contentOf(b)).equals('B one');

      // The second answer (the list tail) finishes first.
      socket.deliver(b, 'chat:completion', {'content': 'B final', 'done': true});
      check(streaming(b)).isFalse();
      check(contentOf(b)).equals('B final');
      check(streaming(a)).isTrue();
      check(contentOf(a)).equals('A one and two');
      check(container.read(isChatStreamingProvider)).isTrue();

      // The first answer keeps streaming after its sibling finished.
      socket.deliver(a, 'chat:completion', {'content': 'A final', 'done': true});
      check(streaming(a)).isFalse();
      check(contentOf(a)).equals('A final');
      check(contentOf(b)).equals('B final');
      check(container.read(isChatStreamingProvider)).isFalse();
    });

    test('a failed answer fails alone and stopping one task leaves the other '
        'running', () async {
      final (:api, :socket, :container) = await open(account: _admin);
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      final [a, b] = [for (final h in handles) h.assistantMessageId];
      await replay(container);

      ChatMessage message(String id) => container
          .read(chatMessagesProvider)
          .firstWhere((candidate) => candidate.id == id);

      socket.deliver(b, 'chat:message:error', {
        'error': {'content': 'model b exploded'},
        'done': true,
      });
      check(message(b).error?.content).equals('model b exploded');
      check(message(b).isStreaming).isFalse();
      check(message(a).error).isNull();
      check(message(a).isStreaming).isTrue();

      socket.deliver(a, 'chat:completion', {'content': 'A partial'});
      await container.read(stopComparisonAnswerProvider)(a);
      check(api.stoppedTasks).deepEquals(['task-0']);
      check(message(a).isStreaming).isFalse();
      check(message(a).content).equals('A partial');
    });

    group('stopping one answer needs the server to accept it', () {
      Future<
        ({
          _FanOutApi api,
          ProviderContainer container,
          ChatMessage Function(String) message,
          String a,
          String b,
        })
      >
      running(User account) async {
        final (:api, :socket, :container) = await open(account: account);
        final handles = await durableCompareSend(
          container,
          'compare these',
          null,
          models: const [duplicate, duplicate],
        );
        final [a, b] = [for (final h in handles) h.assistantMessageId];
        await replay(container);
        socket.deliver(a, 'chat:completion', {'content': 'A partial'});
        socket.deliver(b, 'chat:completion', {'content': 'B partial'});
        return (
          api: api,
          container: container,
          message: (String id) => container
              .read(chatMessagesProvider)
              .firstWhere((candidate) => candidate.id == id),
          a: a,
          b: b,
        );
      }

      test('a regular user is never sent to the admin-only route, even by a '
          'stale call', () async {
        final (:api, :container, :message, :a, :b) = await running(_accountA);

        await container.read(stopComparisonAnswerProvider)(a);

        check(api.stoppedTasks).isEmpty();
        for (final id in [a, b]) {
          check(message(id).isStreaming).isTrue();
          check(message(id).error).isNull();
        }
        check(message(a).metadata?['taskId']).equals('task-0');
        check(message(a).content).equals('A partial');
      });

      test('a refused stop leaves the answer live, with its text and task, '
          'and its sibling untouched', () async {
        final (:api, :container, :message, :a, :b) = await running(_admin);
        api.stopFailure = DioException.badResponse(
          statusCode: 401,
          requestOptions: RequestOptions(path: '/api/tasks/stop/task-0'),
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: '/api/tasks/stop/task-0'),
            statusCode: 401,
          ),
        );

        await container.read(stopComparisonAnswerProvider)(a);

        check(api.stoppedTasks).deepEquals(['task-0']);
        check(message(a).isStreaming).isTrue();
        check(message(a).content).equals('A partial');
        check(message(a).metadata?['taskId']).equals('task-0');
        check(message(a).error).isNull();
        check(message(b).isStreaming).isTrue();
        check(message(b).content).equals('B partial');
        check(message(b).metadata?['taskId']).equals('task-1');
      });

      test('the answer settles only once the server has acknowledged, and '
          'then only that answer', () async {
        final (:api, :container, :message, :a, :b) = await running(_admin);
        final acknowledge = Completer<void>();
        api.holdStop = acknowledge;

        final stopping = container.read(stopComparisonAnswerProvider)(a);
        await Future<void>.delayed(Duration.zero);
        check(api.stoppedTasks).deepEquals(['task-0']);
        check(message(a).isStreaming).isTrue();

        acknowledge.complete();
        await stopping;
        check(message(a).isStreaming).isFalse();
        check(message(a).content).equals('A partial');
        check(message(b).isStreaming).isTrue();
      });

      // The second sign-in is the same account, so only the authentication
      // session tells it apart from the one that asked.
      for (final (name, signIns) in [
        ('the account changed', [_accountB]),
        ('the same account left and signed back in', [_accountB, _admin]),
      ]) {
        test('an acknowledgement that arrives after $name alters nothing '
            'for the new sign-in', () async {
          final (:api, :container, :message, :a, :b) = await running(_admin);
          final acknowledge = Completer<void>();
          api.holdStop = acknowledge;

          // The app always has the authentication session observed (the socket
          // and chat sync providers watch it), and a sign-in never follows
          // another without the network between them, so each one is seen as
          // it happens rather than collapsed into the account it returns to.
          container.listen(openWebUiAuthSessionEpochProvider, (_, _) {});
          final stopping = container.read(stopComparisonAnswerProvider)(a);
          await Future<void>.delayed(Duration.zero);
          final askedUnder = container.read(openWebUiAuthSessionEpochProvider);
          for (final account in signIns) {
            container.read(_switchableAccountProvider.notifier).signIn(account);
            await Future<void>.delayed(Duration.zero);
          }
          check(
            identical(
              askedUnder,
              container.read(openWebUiAuthSessionEpochProvider),
            ),
          ).isFalse();
          acknowledge.complete();
          await stopping;

          check(message(a).isStreaming).isTrue();
          check(message(a).content).equals('A partial');
          check(message(a).error).isNull();
          check(message(b).isStreaming).isTrue();
        });
      }
    });

    test('stop-all settles every answer, including one that is not the '
        'list tail, for a regular user', () async {
      final (:api, :socket, :container) = await open(account: _accountA);
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      final [a, b] = [for (final h in handles) h.assistantMessageId];
      await replay(container);

      // The tail finished; the first answer is still running.
      socket.deliver(b, 'chat:completion', {'content': 'B', 'done': true});
      check(container.read(isChatStreamingProvider)).isTrue();

      container.read(stopGenerationProvider)();
      // The stop also drops the chat's queued op and stops its tasks; let those
      // finish before the database goes away.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      // One chat-wide stop covers the tasks of every answer.
      check(api.stoppedChats).isNotEmpty();
      check(api.stoppedChats.toSet()).deepEquals({chatId});
      check(container.read(isChatStreamingProvider)).isFalse();
      check(
        container
            .read(chatMessagesProvider)
            .where((m) => m.role == 'assistant')
            .every((m) => !m.isStreaming),
      ).isTrue();
      // The first answer kept what it had streamed.
      socket.deliver(a, 'chat:completion', {'content': 'late text'});
      check(
        container
            .read(chatMessagesProvider)
            .firstWhere((m) => m.id == a)
            .isStreaming,
      ).isFalse();
    });

    test('a replay after acceptance never sends the group again, even when '
        'only one answer shows it was accepted', () async {
      final (:api, :socket, :container) = await open();
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      await replay(container);
      check(api.requests).length.equals(1);

      await replay(container);
      check(api.requests).length.equals(1);

      // Only the FIRST answer carries any sign now: the second looks fresh.
      final second = handles.last.assistantMessageId;
      final row = (await db.messagesDao.getMessage(chatId, second))!;
      final payload = jsonDecode(row.payload) as Map<String, dynamic>
        ..remove('metadata');
      await db.messagesDao.upsertLocalEcho(
        MessageRowData(
          id: row.id,
          chatId: chatId,
          parentId: row.parentId,
          role: 'assistant',
          content: '',
          model: row.model,
          createdAt: row.createdAt,
          orderIndex: row.orderIndex,
          payload: payload,
        ),
      );
      await replay(container);
      check(api.requests).length.equals(1);
    });

    test('an answer that landed first does not complete the group', () async {
      final (:api, :socket, :container) = await open();
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      // The first answer finished (its marker says so) before any replay ran
      // with a stored acceptance marker on the second.
      await db.messagesDao.markAssistantCompletionRecoveryFailed(
        chatId: chatId,
        messageId: handles.first.assistantMessageId,
        error: 'finished elsewhere',
      );

      await replay(container);

      // It is recovery, not a fresh request, and the second is settled with a
      // reason instead of being left as a silent empty bubble.
      check(api.requests).isEmpty();
      final second = (await db.messagesDao.getMessage(
        chatId,
        handles.last.assistantMessageId,
      ))!;
      final payload = jsonDecode(second.payload) as Map<String, dynamic>;
      check(payload['error']).isNotNull();
    });

    test('an unusable snapshot is refused rather than sent as a single '
        'answer', () async {
      final (:api, :socket, :container) = await open();
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      final op = (await db.outboxDao.pendingForChat(
        chatId,
      )).singleWhere((op) => op.kind == 'requestCompletion');
      final payload = jsonDecode(op.payload) as Map<String, dynamic>;
      // A group with one slot left decodes as a group, not as "no group".
      (payload['comparison'] as Map<String, dynamic>)['slots'] = [
        (payload['comparison']['slots'] as List).first,
      ];

      await check(
        runnerFor(container).run(chatId: chatId, payload: payload),
      ).throws<SyncTerminalException>();
      check(api.requests).isEmpty();
      check(handles).length.equals(2);
    });

    // Only an ABSENT `comparison` key is a single-answer turn. Whatever else
    // the stored op holds, a group that cannot be read is refused: sent as an
    // ordinary completion it would lose answers, and a shortened group would
    // silently drop one.
    final damages = <String, Object? Function(Map<String, dynamic> group)>{
      'null': (_) => null,
      'scalar': (_) => 'damaged snapshot',
      'a snapshot with no slots': (group) => {
        'userMessageId': group['userMessageId'],
      },
      'a damaged third slot': (group) => {
        ...group,
        'slots': [...(group['slots'] as List), <String, dynamic>{}],
      },
      'a scalar third slot': (group) => {
        ...group,
        'slots': [...(group['slots'] as List), 'asst-2'],
      },
      'repeated answer ids': (group) {
        final slots = group['slots'] as List;
        return {
          ...group,
          'slots': [
            slots.first,
            {
              ...(slots.last as Map<String, dynamic>),
              'assistantMessageId':
                  (slots.first as Map<String, dynamic>)['assistantMessageId'],
            },
          ],
        };
      },
    };
    for (final headless in [false, true]) {
      for (final damage in damages.entries) {
        test('a damaged snapshot (${damage.key}) is refused without a request '
            '${headless ? 'when the chat is not on screen' : 'on screen'}', () async {
          final (:api, :socket, :container) = await open();
          await durableCompareSend(
            container,
            'compare these',
            null,
            models: const [duplicate, duplicate],
          );
          final op = (await db.outboxDao.pendingForChat(
            chatId,
          )).singleWhere((op) => op.kind == 'requestCompletion');
          final payload = jsonDecode(op.payload) as Map<String, dynamic>;
          payload['comparison'] = damage.value(
            payload['comparison'] as Map<String, dynamic>,
          );
          if (headless) {
            (container.read(chatMessagesProvider.notifier)
                    as _TestMessagesNotifier)
                .setMessages(const <ChatMessage>[]);
            container
                .read(activeConversationProvider.notifier)
                .set(
                  _conversation(
                    'another-chat',
                    const <ChatMessage>[],
                    ChatStorageKind.openWebUi,
                  ),
                );
          }

          await check(
            runnerFor(container).run(chatId: chatId, payload: payload),
          ).throws<SyncTerminalException>();
          check(api.requests).isEmpty();
        });
      }
    }

    test('an op queued before comparisons existed still replays as an '
        'ordinary single answer', () async {
      final (:api, :socket, :container) = await open();
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      final op = (await db.outboxDao.pendingForChat(
        chatId,
      )).singleWhere((op) => op.kind == 'requestCompletion');
      final payload = jsonDecode(op.payload) as Map<String, dynamic>
        ..remove('comparison');
      check(RequestCompletionPayload.fromJson(payload).comparison).isNull();
      // Replayed with another chat on screen, as the drainer would after a
      // restart, so the turn's own streaming placeholders do not hold it.
      (container.read(chatMessagesProvider.notifier) as _TestMessagesNotifier)
          .setMessages(const <ChatMessage>[]);
      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation(
              'another-chat',
              const <ChatMessage>[],
              ChatStorageKind.openWebUi,
            ),
          );

      await runnerFor(container).run(chatId: chatId, payload: payload);

      check(api.requests).length.equals(1);
      check(api.requests.single.messageIds).isNull();
      check(api.requests.single.responseMessageId)
          .equals(handles.first.assistantMessageId);
    });

    test('a failed drain after the turn is committed keeps the turn on screen '
        'and its one op queued, so nothing invites a second send', () async {
      final (:api, :socket, :container) = await open(
        engine: _ThrowingDrainEngine.new,
      );

      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );

      check(handles).length.equals(2);
      check(
        (await db.outboxDao.pendingForChat(
          chatId,
        )).where((op) => op.kind == 'requestCompletion'),
      ).length.equals(1);
      check(
        container.read(chatMessagesProvider).map((m) => m.id),
      ).deepEquals([
        'u0',
        (await db.messagesDao.getForChat(chatId))
            .singleWhere((row) => row.role == 'user')
            .id,
        for (final handle in handles) handle.assistantMessageId,
      ]);
      check(api.requests).isEmpty();
    });

    test('an existing chat\'s model list and answers are in the rebuilt chat '
        'blob, beside every field the server keeps', () async {
      final (:api, :socket, :container) = await open(
        storedBlob: <String, dynamic>{
          'title': 'A',
          'models': <String>['older-model'],
          'params': <String, dynamic>{'temperature': 0.2},
          'x_upstream_only': <String, dynamic>{'keep': true},
          'history': <String, dynamic>{
            'currentId': 'u0',
            'messages': <String, dynamic>{
              'u0': <String, dynamic>{
                'id': 'u0',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'earlier',
                'timestamp': 1,
              },
            },
          },
        },
      );

      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );

      final blob = await rebuiltBlob(chatId);
      check(blob['models']).isA<List<Object?>>().deepEquals([
        'model-1',
        'model-1',
      ]);
      check(blob['params']).isA<Map<String, dynamic>>().deepEquals({
        'temperature': 0.2,
      });
      check(blob['x_upstream_only']).isA<Map<String, dynamic>>().deepEquals({
        'keep': true,
      });
      _expectComparisonHistory(blob, handles);
    });

    test('a new chat\'s blob holds the same model list and answers', () async {
      final api = _FanOutApi();
      final container = _container(
        db: db,
        active: null,
        messages: const <ChatMessage>[],
        api: api,
        syncEngine: _QuietSyncEngine(db, api),
        socket: _GroupSocket(chatId: chatId, connected: true),
        extraOverrides: [
          modelsProvider.overrideWith(() => _ListedModels(const [duplicate])),
        ],
      );
      addTearDown(container.dispose);
      await container.read(modelsProvider.future);

      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );

      final localId = container.read(activeConversationProvider)!.id;
      final blob = await rebuiltBlob(localId);
      check(blob['models']).isA<List<Object?>>().deepEquals([
        'model-1',
        'model-1',
      ]);
      _expectComparisonHistory(blob, handles);
    });

    test('a server that answers one response keeps it and explains the '
        'rest, without sending again', () async {
      final (:api, :socket, :container) = await open();
      api.answerSynchronously = true;
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );

      await replay(container);

      check(api.requests).length.equals(1);
      final second = (await db.messagesDao.getMessage(
        chatId,
        handles.last.assistantMessageId,
      ))!;
      final payload = jsonDecode(second.payload) as Map<String, dynamic>;
      check(
        (payload['error'] as Map<String, dynamic>)['content'],
      ).isA<String>().contains('cannot compare');
    });

    test('mixed reasoning-effort support is refused in either slot order '
        'until the override is removed', () async {
      const reasoning = Model(
        id: 'reasoner',
        name: 'Reasoner',
        supportedParameters: ['reasoning_effort'],
      );
      const plain = Model(id: 'plain', name: 'Plain');
      final (:api, :socket, :container) = await open(
        available: const [reasoning, plain],
        storedParams: {'reasoning_effort': 'high'},
      );

      for (final order in [
        const [reasoning, plain],
        const [plain, reasoning],
      ]) {
        await check(
          durableCompareSend(container, 'compare', null, models: order),
        ).throws<ComparisonAdmissionException>(
          (it) => it
              .has((e) => e.reason, 'reason')
              .equals(ComparisonAdmissionFailure.settingsConflict),
        );
      }
      // Nothing was written or left on screen by the refusals.
      check(await db.messagesDao.getForChat(chatId)).isEmpty();
      check(await db.outboxDao.pendingForChat(chatId)).isEmpty();
      check(container.read(chatMessagesProvider)).length.equals(1);
      check(api.requests).isEmpty();

      await db.chatsDao.patchChatParamsWithOutbox(
        chatId,
        remove: const ['reasoning_effort'],
        updatedAt: 9,
      );
      await db.delete(db.outboxDao.outboxOps).go();

      await durableCompareSend(
        container,
        'compare',
        null,
        models: const [plain, reasoning],
      );
      await replay(container);
      check(api.requests).length.equals(1);
      check(api.requests.single.chatParams).isNotNull().not(
        (it) => it.containsKey('reasoning_effort'),
      );
    });

    test('a chat that is not on screen is driven headlessly: one request, '
        'every answer reconciled, none streamed into the wrong chat', () async {
      final (:api, :socket, :container) = await open(
        engine: (db, api) => _PartialLandingEngine(db, api),
      );
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      final [a, b] = [for (final h in handles) h.assistantMessageId];
      (container.read(chatMessagesProvider.notifier) as _TestMessagesNotifier)
          .setMessages(const <ChatMessage>[]);
      container
          .read(activeConversationProvider.notifier)
          .set(
            _conversation('another-chat', const [], ChatStorageKind.openWebUi),
          );
      (container.read(syncEngineProvider.notifier) as _PartialLandingEngine)
          .landedIds = [a];

      await replay(container);

      check(api.requests).length.equals(1);
      check(api.requests.single.messageIds!.map((t) => t.messageId)).deepEquals(
        [a, b],
      );
      // Nothing streams into the chat on screen: no handler was attached.
      check(socket.handlers).isEmpty();
      // The answer that landed is left alone; the one that never did is settled
      // with a reason instead of staying a silent empty bubble.
      final first = jsonDecode(
        (await db.messagesDao.getMessage(chatId, a))!.payload,
      ) as Map<String, dynamic>;
      final second = jsonDecode(
        (await db.messagesDao.getMessage(chatId, b))!.payload,
      ) as Map<String, dynamic>;
      check(first.containsKey('error')).isFalse();
      check(second['error']).isNotNull();
      for (final payload in [first, second]) {
        check((payload['metadata'] as Map)['completionSubmitted']).equals(true);
      }
    });

    test('an account change during a delayed response sends nothing again and '
        'streams nothing into the next account', () async {
      final (:api, :socket, :container) = await open(trackSignIn: true);
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      api.holdResponse = Completer<void>();

      final replaying = replay(container);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      check(api.requests).length.equals(1);

      // Another account signs in while the server is still answering.
      container.read(_signInEpochProvider.notifier).rotate();
      api.holdResponse!.complete();
      await replaying;

      check(api.requests).length.equals(1);
      check(socket.handlers).isEmpty();
      // The earlier account's answers received nothing from the late response.
      for (final handle in handles) {
        final shown = container
            .read(chatMessagesProvider)
            .firstWhere((m) => m.id == handle.assistantMessageId);
        check(shown.content).isEmpty();
        check(shown.metadata?['taskId']).isNull();
      }
    });

    test('regenerating the second answer asks for ONLY that answer, in its own '
        'column, with its own model', () async {
      const other = Model(id: 'model-2', name: 'Model 2');
      final (:api, :socket, :container) = await open(
        available: const [duplicate, other],
      );
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, other],
      );
      final [a, b] = [for (final h in handles) h.assistantMessageId];
      await replay(container);
      socket.deliver(a, 'chat:completion', {'content': 'A', 'done': true});
      socket.deliver(b, 'chat:completion', {'content': 'B', 'done': true});
      check(api.requests).length.equals(1);

      // The picker holds the first model; the answer being redone is the
      // second slot's, so that model must be asked, in that column.
      await regenerateMessage(container, 'compare these', null);

      check(api.requests).length.equals(2);
      final request = api.requests.last;
      check(request.model).equals('model-2');
      check(request.messageIds).isNotNull().length.equals(1);
      check(request.messageIds!.single.modelId).equals('model-2');
      check(request.messageIds!.single.modelIdx).equals(1);
      final regenerated = container
          .read(chatMessagesProvider)
          .firstWhere((m) => m.id == request.messageIds!.single.messageId);
      check(regenerated.modelSlot).equals(1);
    });

    test('a model the server does not list is refused before anything is '
        'written', () async {
      final (:api, :socket, :container) = await open();
      await check(
        durableCompareSend(
          container,
          'compare',
          null,
          models: const [duplicate, Model(id: 'ghost', name: 'Ghost')],
        ),
      ).throws<ComparisonAdmissionException>(
        (it) => it
            .has((e) => e.reason, 'reason')
            .equals(ComparisonAdmissionFailure.modelUnavailable),
      );
      check(await db.outboxDao.pendingForChat(chatId)).isEmpty();
    });

    /// A new draft showing 'original-project' whose account settings have not
    /// been answered yet: the window in which it can move on before it is
    /// admitted. Nothing has been sent when this returns.
    Future<({_FanOutApi api, ProviderContainer container})>
    projectDraftAwaitingSettings({bool trackSignIn = false}) async {
      final api = _FanOutApi()..holdSettings = Completer<void>();
      final container = _container(
        db: db,
        active: null,
        messages: const <ChatMessage>[],
        api: api,
        syncEngine: _QuietSyncEngine(db, api),
        extraOverrides: [
          isOnlineProvider.overrideWithValue(true),
          currentUserProvider2.overrideWithValue(
            const User(
              id: 'me',
              username: 'Me',
              email: 'me@example.com',
              role: 'user',
            ),
          ),
          modelsProvider.overrideWith(() => _ListedModels(const [duplicate])),
          if (trackSignIn)
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(_signInEpochProvider),
            ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(modelsProvider.future);
      container.read(pendingFolderIdProvider.notifier).set('original-project');
      return (api: api, container: container);
    }

    group('a project draft whose admission waits on the account settings', () {
      Future<
        ({
          _FanOutApi api,
          ProviderContainer container,
          Future<List<ChatSendPlaceholderHandle>> admitted,
          List<String> navigated,
        })
      >
      begin({bool trackSignIn = false}) async {
        final (:api, :container) = await projectDraftAwaitingSettings(
          trackSignIn: trackSignIn,
        );
        final navigated = <String>[];
        final admitted = durableCompareSend(
          container,
          'Original project draft',
          null,
          models: const [duplicate, duplicate],
          onCommitted: () => navigated.add('chat'),
        );
        await api.settingsEntered.future.timeout(const Duration(seconds: 10));
        // Nothing is written, and nobody is sent anywhere, while it waits.
        check(await db.chatsDao.watchChatList().first).isEmpty();
        check(navigated).isEmpty();
        return (
          api: api,
          container: container,
          admitted: admitted,
          navigated: navigated,
        );
      }

      /// The one turn the original draft admitted: one chat in its project, one
      /// user row, one answer per model and one completion op.
      Future<void> expectOriginalTurnAdmittedOnce() async {
        final chats = await db.chatsDao.watchChatList().first;
        check(chats).length.equals(1);
        check(chats.single.folderId).equals('original-project');
        final rows = await db.messagesDao.getForChat(chats.single.id);
        check(rows.where((row) => row.role == 'user')).length.equals(1);
        check(rows.where((row) => row.role == 'assistant')).length.equals(2);
        final ops = await db.outboxDao.pendingForChat(chats.single.id);
        check(
          ops.where((op) => op.kind == 'requestCompletion'),
        ).length.equals(1);
      }

      test('an unchanged draft is admitted in its project and opens the chat '
          'exactly once', () async {
        final (:api, :container, :admitted, :navigated) = await begin();

        api.holdSettings!.complete();
        final handles = await admitted;

        check(handles).length.equals(2);
        await expectOriginalTurnAdmittedOnce();
        check(navigated).deepEquals(['chat']);
        final active = container.read(activeConversationProvider)!;
        check(active.folderId).equals('original-project');
        check(container.read(pendingFolderIdProvider)).isNull();
        check(
          container.read(chatMessagesProvider).map((m) => m.id),
        ).deepEquals([
          handles.first.userMessageId!,
          for (final handle in handles) handle.assistantMessageId,
        ]);
      });

      test('a draft that moved to another project keeps the project that '
          'admitted the turn and is left alone', () async {
        final (:api, :container, :admitted, :navigated) = await begin();
        // What the folder page does when another project starts a draft.
        container.read(pendingFolderIdProvider.notifier).set('new-project');
        container.read(chatMessagesProvider.notifier).setMessages([
          _user('newer', 'A newer draft'),
        ]);

        api.holdSettings!.complete();
        final handles = await admitted;

        check(handles).length.equals(2);
        await expectOriginalTurnAdmittedOnce();
        check(navigated).isEmpty();
        check(container.read(pendingFolderIdProvider)).equals('new-project');
        check(container.read(activeConversationProvider)).isNull();
        check(
          container.read(chatMessagesProvider).map((m) => m.id),
        ).deepEquals(['newer']);
      });

      test('a draft that only changed project does not keep the rows of a '
          'turn that went elsewhere', () async {
        final (:api, :container, :admitted, :navigated) = await begin();
        container.read(pendingFolderIdProvider.notifier).set('new-project');

        api.holdSettings!.complete();
        await admitted;

        await expectOriginalTurnAdmittedOnce();
        check(navigated).isEmpty();
        check(container.read(pendingFolderIdProvider)).equals('new-project');
        check(container.read(activeConversationProvider)).isNull();
        check(container.read(chatMessagesProvider)).isEmpty();
      });

      test('a newer draft in the same project is not given the old rows or '
          'cleared', () async {
        final (:api, :container, :admitted, :navigated) = await begin();
        container.read(chatMessagesProvider.notifier).setMessages([
          _user('newer', 'A newer draft'),
        ]);

        api.holdSettings!.complete();
        await admitted;

        await expectOriginalTurnAdmittedOnce();
        check(navigated).isEmpty();
        check(
          container.read(pendingFolderIdProvider),
        ).equals('original-project');
        check(container.read(activeConversationProvider)).isNull();
        check(
          container.read(chatMessagesProvider).map((m) => m.id),
        ).deepEquals(['newer']);
      });

      test('a chat opened meanwhile stays on screen and is not navigated '
          'away from', () async {
        final (:api, :container, :admitted, :navigated) = await begin();
        final opened = [_user('b0', 'Another chat')];
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation('chat-b', opened, ChatStorageKind.openWebUi));
        container.read(chatMessagesProvider.notifier).setMessages(opened);

        api.holdSettings!.complete();
        await admitted;

        await expectOriginalTurnAdmittedOnce();
        check(navigated).isEmpty();
        check(container.read(activeConversationProvider)!.id).equals('chat-b');
        check(
          container.read(chatMessagesProvider).map((m) => m.id),
        ).deepEquals(['b0']);
        check(
          container.read(pendingFolderIdProvider),
        ).equals('original-project');
      });

      test('a new sign-in meanwhile keeps the turn in the account that sent '
          'it and presents nothing to the next one', () async {
        final (:api, :container, :admitted, :navigated) = await begin(
          trackSignIn: true,
        );
        container.read(_signInEpochProvider.notifier).rotate();

        api.holdSettings!.complete();
        await admitted;

        await expectOriginalTurnAdmittedOnce();
        check(navigated).isEmpty();
        check(container.read(activeConversationProvider)).isNull();
        check(
          container.read(pendingFolderIdProvider),
        ).equals('original-project');
        check(container.read(chatMessagesProvider)).isEmpty();
      });
    });

    group('an ordinary send whose admission waits on the account settings', () {
      Future<
        ({
          _FanOutApi api,
          ProviderContainer container,
          Future<void> admitted,
          List<ChatSendAdmissionReceipt> receipts,
        })
      >
      begin({
        bool trackSignIn = false,
        String? folderOverride,
        bool withContext = false,
      }) async {
        final (:api, :container) = await projectDraftAwaitingSettings(
          trackSignIn: trackSignIn,
        );
        // Context the composer already holds when the send begins.
        if (withContext) {
          container
              .read(contextAttachmentsProvider.notifier)
              .addWeb(
                displayName: 'Page',
                content: 'page text',
                url: 'https://example.com',
              );
        }
        final receipts = <ChatSendAdmissionReceipt>[];
        final admitted = durableSend(
          container,
          'Original project draft',
          null,
          pendingFolderIdOverride: folderOverride,
          onAdmissionCommitted: receipts.add,
        );
        await api.settingsEntered.future.timeout(const Duration(seconds: 10));
        // Nothing is written, and nothing is certified, while it waits.
        check(await db.chatsDao.watchChatList().first).isEmpty();
        check(receipts).isEmpty();
        return (
          api: api,
          container: container,
          admitted: admitted,
          receipts: receipts,
        );
      }

      /// The one turn the draft admitted in [folder]: one chat, one user row,
      /// one answer and one completion op, certified by exactly one receipt.
      Future<void> expectTurnAdmittedOnce(
        List<ChatSendAdmissionReceipt> receipts, {
        String folder = 'original-project',
      }) async {
        final chats = await db.chatsDao.watchChatList().first;
        check(chats).length.equals(1);
        check(chats.single.folderId).equals(folder);
        final rows = await db.messagesDao.getForChat(chats.single.id);
        check(rows.where((row) => row.role == 'user')).length.equals(1);
        check(rows.where((row) => row.role == 'assistant')).length.equals(1);
        final ops = await db.outboxDao.pendingForChat(chats.single.id);
        check(ops.where((op) => op.kind == 'requestCompletion')).length
            .equals(1);
        check(receipts).length.equals(1);
        check(receipts.single.chatId).equals(chats.single.id);
        check(receipts.single.userMessageId)
            .equals(rows.singleWhere((row) => row.role == 'user').id);
      }

      test('an unchanged draft is admitted in its project and takes over '
          'the screen', () async {
        final (:api, :container, :admitted, :receipts) = await begin(
          withContext: true,
        );

        api.holdSettings!.complete();
        await admitted;

        await expectTurnAdmittedOnce(receipts);
        // The context went into the turn, so the composer no longer carries it.
        check(container.read(contextAttachmentsProvider)).isEmpty();
        final active = container.read(activeConversationProvider)!;
        check(active.id).equals(receipts.single.chatId);
        check(active.folderId).equals('original-project');
        check(container.read(pendingFolderIdProvider)).isNull();
        check(container.read(chatMessagesProvider).map((m) => m.id)).deepEquals(
          [receipts.single.userMessageId, receipts.single.assistantMessageId],
        );
      });

      // What the draft on screen turned into while the admission waited, and
      // what must be left exactly as that draft has it.
      final moved =
          <
            ({
              String name,
              bool trackSignIn,
              void Function(ProviderContainer) change,
              String? pending,
              String? activeId,
              List<String> shown,
            })
          >[
            (
              name:
                  'a draft that moved to another project with its own messages',
              trackSignIn: false,
              change: (container) {
                container
                    .read(pendingFolderIdProvider.notifier)
                    .set('new-project');
                container.read(chatMessagesProvider.notifier).setMessages([
                  _user('newer', 'A newer draft'),
                ]);
              },
              pending: 'new-project',
              activeId: null,
              shown: ['newer'],
            ),
            (
              name: 'a draft that only changed project',
              trackSignIn: false,
              change: (container) => container
                  .read(pendingFolderIdProvider.notifier)
                  .set('new-project'),
              pending: 'new-project',
              activeId: null,
              shown: [],
            ),
            (
              name: 'a newer draft in the same project',
              trackSignIn: false,
              change: (container) => container
                  .read(chatMessagesProvider.notifier)
                  .setMessages([_user('newer', 'A newer draft')]),
              pending: 'original-project',
              activeId: null,
              shown: ['newer'],
            ),
            (
              name: 'a chat opened meanwhile',
              trackSignIn: false,
              change: (container) {
                final opened = [_user('b0', 'Another chat')];
                container
                    .read(activeConversationProvider.notifier)
                    .set(
                      _conversation(
                        'chat-b',
                        opened,
                        ChatStorageKind.openWebUi,
                      ),
                    );
                container
                    .read(chatMessagesProvider.notifier)
                    .setMessages(opened);
              },
              pending: 'original-project',
              activeId: 'chat-b',
              shown: ['b0'],
            ),
            (
              name: 'a new sign-in meanwhile',
              trackSignIn: true,
              change: (container) =>
                  container.read(_signInEpochProvider.notifier).rotate(),
              pending: 'original-project',
              activeId: null,
              shown: [],
            ),
          ];

      for (final scenario in moved) {
        test('${scenario.name} keeps the project that admitted the turn, is '
            'left alone, and the receipt still certifies the turn', () async {
          final (:api, :container, :admitted, :receipts) = await begin(
            trackSignIn: scenario.trackSignIn,
          );
          scenario.change(container);

          api.holdSettings!.complete();
          await admitted;

          await expectTurnAdmittedOnce(receipts);
          check(container.read(pendingFolderIdProvider))
              .equals(scenario.pending);
          check(container.read(activeConversationProvider)?.id)
              .equals(scenario.activeId);
          check(container.read(chatMessagesProvider).map((m) => m.id))
              .deepEquals(scenario.shown);
        });
      }

      test('the context of a draft that moved on is not cleared by a turn '
          'that went elsewhere', () async {
        final (:api, :container, :admitted, :receipts) = await begin(
          withContext: true,
        );
        container.read(pendingFolderIdProvider.notifier).set('new-project');

        api.holdSettings!.complete();
        await admitted;

        await expectTurnAdmittedOnce(receipts);
        check(container.read(contextAttachmentsProvider)).length.equals(1);
      });

      test('an explicit project is the one the turn is stored in, and an '
          'unchanged draft still takes over the screen', () async {
        final (:api, :container, :admitted, :receipts) = await begin(
          folderOverride: 'folder-page-project',
        );

        api.holdSettings!.complete();
        await admitted;

        await expectTurnAdmittedOnce(receipts, folder: 'folder-page-project');
        check(container.read(activeConversationProvider)!.folderId)
            .equals('folder-page-project');
        check(container.read(pendingFolderIdProvider)).isNull();
      });

      test('an explicit project keeps its turn when the visible draft moved '
          'to another project', () async {
        final (:api, :container, :admitted, :receipts) = await begin(
          folderOverride: 'folder-page-project',
        );
        container.read(pendingFolderIdProvider.notifier).set('new-project');

        api.holdSettings!.complete();
        await admitted;

        await expectTurnAdmittedOnce(receipts, folder: 'folder-page-project');
        check(container.read(pendingFolderIdProvider)).equals('new-project');
        check(container.read(activeConversationProvider)).isNull();
        check(container.read(chatMessagesProvider)).isEmpty();
      });
    });
  });

  group('a comparison started from a draft stays live once its chat exists', () {
    const duplicate = Model(id: 'model-1', name: 'Model 1', isMultimodal: true);

    /// The whole stack a new comparison crosses: the real sync engine creates the
    /// chat on a server double and remaps its id, the real notifiers watch the
    /// rows, and the real runner sends the group. Only the server's answers are
    /// held back.
    Future<
      ({
        _FanOutApi api,
        _GroupSocket socket,
        FakeSyncApiClient client,
        ProviderContainer container,
      })
    >
    openDraft({bool rotatableSignIn = false, User? account}) async {
      final server = FakeOpenWebUiServer();
      final client = FakeSyncApiClient(server);
      final api = _FanOutApi();
      final socket = _GroupSocket(chatId: 'unassigned');
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(database: db),
          apiServiceProvider.overrideWithValue(api),
          selectedModelProvider.overrideWithValue(duplicate),
          reviewerModeProvider.overrideWithValue(false),
          socketServiceProvider.overrideWithValue(socket),
          temporaryChatEnabledProvider.overrideWith(_FalseTemporaryChat.new),
          webSearchEnabledProvider.overrideWith(_FalseWebSearch.new),
          imageGenerationEnabledProvider.overrideWith(_FalseImageGeneration.new),
          webSearchAvailableProvider.overrideWithValue(false),
          imageGenerationAvailableProvider.overrideWithValue(false),
          selectedFilterIdsProvider.overrideWithValue(const <String>[]),
          selectedTerminalIdProvider.overrideWithValue(null),
          modelsProvider.overrideWith(() => _ListedModels(const [duplicate])),
          syncApiClientProvider.overrideWith((ref) => client),
          isAuthenticatedProvider2.overrideWith((ref) => true),
          if (account != null) ..._signedInAs(account),
          if (rotatableSignIn)
            openWebUiAuthSessionEpochProvider.overrideWith(
              (ref) => ref.watch(_signInEpochProvider),
            ),
          requestCompletionRunnerProvider.overrideWith(
            (ref) => ChatRequestCompletionRunner(
              ref,
              recoveryAttempts: 2,
              recoveryDelay: Duration.zero,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(modelsProvider.future);
      container.read(remapRouteSyncProvider);
      container.read(chatMessagesProvider);
      return (api: api, socket: socket, client: client, container: container);
    }

    /// Waits for work that settles on its own through the event loop.
    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 200 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      check(condition()).isTrue();
    }

    /// A draft compared across two runs of one model, sent, created and
    /// remapped: both answers are running on the server and nothing has arrived.
    Future<
      ({
        _FanOutApi api,
        _GroupSocket socket,
        FakeSyncApiClient client,
        ProviderContainer container,
        String serverId,
        String a,
        String b,
      })
    >
    startComparison({User? account, bool rotatableSignIn = false}) async {
      final (:api, :socket, :client, :container) = await openDraft(
        account: account,
        rotatableSignIn: rotatableSignIn,
      );
      final handles = await durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      final serverId = container.read(activeConversationProvider)!.id;
      socket.chatId = serverId;
      return (
        api: api,
        socket: socket,
        client: client,
        container: container,
        serverId: serverId,
        a: handles.first.assistantMessageId,
        b: handles.last.assistantMessageId,
      );
    }

    ChatMessage answer(ProviderContainer container, String id) => container
        .read(chatMessagesProvider)
        .firstWhere((message) => message.id == id);

    Future<List<MessageRow>> userTurns(String chatId) async =>
        (await db.messagesDao.getForChat(
          chatId,
        )).where((row) => row.role == 'user').toList();

    Future<Map<String, dynamic>> storedAnswer(String chatId, String id) async =>
        jsonDecode((await db.messagesDao.getMessage(chatId, id))!.payload)
            as Map<String, dynamic>;

    /// What a stopped answer must be in the store whatever turn follows it: the
    /// answer the user saw, finished, in its own column under the same user
    /// turn. The server keeps a stopped answer as its last running checkpoint,
    /// so nothing but this write ever marks it done.
    Future<void> expectStoppedAnswer(
      String chatId, {
      required String id,
      required String content,
      required int slot,
      required String taskId,
    }) async {
      final row = (await db.messagesDao.getMessage(chatId, id))!;
      final payload = jsonDecode(row.payload) as Map<String, dynamic>;
      check(payload['done']).equals(true);
      check(payload['isStreaming']).not((it) => it.equals(true));
      check(payload['error']).isNull();
      check(payload['content']).equals(content);
      check(payload['modelIdx']).equals(slot);
      check(row.parentId).equals((await userTurns(chatId)).first.id);
      // What the server kept of the answer is kept with it.
      final metadata = payload['metadata'] as Map<String, dynamic>;
      check(metadata['completionSubmitted']).equals(true);
      check(metadata['taskId']).equals(taskId);
    }

    /// The comparison's answers as a reopen reads them from the stored rows:
    /// the one on the branch, and the others as its versions.
    Future<({ChatMessage shown, Map<String, String> contents})> reopened(
      String chatId,
      Set<String> ids,
    ) async {
      final conversation = assembleConversation(
        (await db.chatsDao.getChat(chatId))!,
        await db.messagesDao.getForChat(chatId),
      );
      final shown = conversation.messages.firstWhere(
        (message) => ids.contains(message.id),
      );
      return (
        shown: shown,
        contents: {
          shown.id: shown.content,
          for (final version in shown.versions) version.id: version.content,
        },
      );
    }

    /// The database itself refuses to store either answer as finished, until
    /// the returned function lifts that.
    Future<Future<void> Function()> rejectStoppedAnswers(
      String a,
      String b,
    ) async {
      await db.customStatement('''
        CREATE TEMP TRIGGER stopped_answer_store_rejected
        BEFORE UPDATE OF payload ON messages
        WHEN NEW.id IN ('$a', '$b')
          AND json_extract(NEW.payload, '\$.done') = 1
        BEGIN SELECT RAISE(ABORT, 'stopped answer rejected'); END
      ''');
      Future<void> lift() => db.customStatement(
        'DROP TRIGGER IF EXISTS stopped_answer_store_rejected',
      );
      addTearDown(lift);
      return lift;
    }

    test('both answers keep running once the chat is created and remapped, '
        'each bound to its own task, and a queue waits for the last', () async {
      final (:api, :socket, :client, :container, :serverId, :a, :b) =
          await startComparison(account: _admin);

      // One real create and one fanout request, under a new server id.
      check(client.createChatCalls).equals(1);
      check(api.requests).length.equals(1);
      check(serverId.startsWith('local:')).isFalse();

      // Neither answer was settled while the server still runs its task: each
      // is still its own message, in its own column, bound to its own task.
      check(
        container
            .read(chatMessagesProvider)
            .where((message) => message.role == 'assistant')
            .map((message) => message.id),
      ).deepEquals([a, b]);
      check(answer(container, a).modelSlot).equals(0);
      check(answer(container, b).modelSlot).equals(1);
      check(answer(container, a).metadata?['taskId']).equals('task-0');
      check(answer(container, b).metadata?['taskId']).equals('task-1');
      for (final id in [a, b]) {
        check(answer(container, id).isStreaming).isTrue();
        check(answer(container, id).error).isNull();
        final payload =
            jsonDecode((await db.messagesDao.getMessage(serverId, id))!.payload)
                as Map<String, dynamic>;
        check(payload['error']).isNull();
        check(payload['done']).not((it) => it.equals(true));
      }

      // Events reach only their own answer.
      socket.deliver(a, 'chat:completion', {'content': 'A so far'});
      socket.deliver(b, 'chat:completion', {'content': 'B so far'});
      check(answer(container, a).content).equals('A so far');
      check(answer(container, b).content).equals('B so far');

      // Drafts wait behind the whole comparison, not behind its first answer.
      final queue = container.read(chatDraftQueueProvider.notifier);
      check(queue.enqueue('first')).isNotNull();
      check(queue.enqueue('second')).isNotNull();

      // Stopping one answer stops its task alone and leaves its sibling live.
      await container.read(stopComparisonAnswerProvider)(a);
      check(api.stoppedTasks).deepEquals(['task-0']);
      check(answer(container, a).isStreaming).isFalse();
      check(answer(container, a).content).equals('A so far');
      check(answer(container, b).isStreaming).isTrue();
      await Future<void>.delayed(Duration.zero);
      check(container.read(chatDraftQueueProvider).single.drafts).length
          .equals(2);
      check(api.requests).length.equals(1);

      // The last answer ends the turn, and the drafts go out once, together.
      socket.deliver(b, 'chat:completion', {'content': 'B final', 'done': true});
      await until(() => api.requests.length == 2);
      await until(() => container.read(chatDraftQueueProvider).isEmpty);
      check((await userTurns(serverId)).map((row) => row.content)).deepEquals([
        'compare these',
        'first\n\nsecond',
      ]);
      await Future<void>.delayed(Duration.zero);
      check(api.requests).length.equals(2);

      // The comparison itself was never sent again.
      check(client.createChatCalls).equals(1);
      socket.deliver(
        api.requests.last.responseMessageId!,
        'chat:completion',
        {'content': 'next', 'done': true},
      );
    });

    test('stopping the whole turn stops every task and releases the queue '
        'once', () async {
      final (:api, :socket, :client, :container, :serverId, :a, :b) =
          await startComparison();
      final queue = container.read(chatDraftQueueProvider.notifier);
      check(queue.enqueue('first')).isNotNull();
      check(queue.enqueue('second')).isNotNull();
      socket.deliver(a, 'chat:completion', {'content': 'A so far'});

      container.read(stopGenerationProvider)();
      await until(() => api.requests.length == 2);
      await until(() => container.read(chatDraftQueueProvider).isEmpty);

      // One chat-wide stop covers the task of each answer, whichever is running.
      check(api.stoppedChats.toSet()).deepEquals({serverId});
      check(answer(container, a).content).equals('A so far');
      for (final id in [a, b]) {
        check(answer(container, id).isStreaming).isFalse();
      }
      check((await userTurns(serverId)).map((row) => row.content)).deepEquals([
        'compare these',
        'first\n\nsecond',
      ]);
      await Future<void>.delayed(Duration.zero);
      check(api.requests).length.equals(2);
      socket.deliver(
        api.requests.last.responseMessageId!,
        'chat:completion',
        {'content': 'next', 'done': true},
      );
      await until(
        () => container
            .read(chatMessagesProvider)
            .any((message) => message.content == 'next'),
      );
      await Future<void>.delayed(Duration.zero);

      // Both answers are stored as finished with the text they had, although
      // the next turn has since moved the transcript on: neither is left for a
      // pull or a reopen to read as the running checkpoint the server kept.
      final bText = answer(container, b).content;
      await expectStoppedAnswer(
        serverId,
        id: a,
        content: 'A so far',
        slot: 0,
        taskId: 'task-0',
      );
      await expectStoppedAnswer(
        serverId,
        id: b,
        content: bText,
        slot: 1,
        taskId: 'task-1',
      );
      final group = await reopened(serverId, {a, b});
      check(group.shown.isStreaming).isFalse();
      check(group.shown.metadata?[kMessageUnfinishedAnswersMetadataKey])
          .isNull();
      check(group.contents).deepEquals({a: 'A so far', b: bText});
    });

    // The same Send now, once with the store taking the stopped answers and once
    // with it rejecting them: the server's tasks are stopped either way, and
    // only a stop whose answers are stored goes on to admit the chosen draft.
    for (final storeRejects in [false, true]) {
        test(
          storeRejects
              ? 'Send now does not admit when the stopped answers cannot be '
                    'stored, and keeps both drafts'
              : 'Send now stops a comparison, stores its answers as finished, '
                    'and admits only the chosen draft once they are stored',
          () async {
            final (:api, :socket, :client, :container, :serverId, :a, :b) =
                await startComparison();
            final queue = container.read(chatDraftQueueProvider.notifier);
            queue.enqueue('first');
            final second = queue.enqueue('second')!;
            socket.deliver(a, 'chat:completion', {'content': 'A so far'});
            socket.deliver(b, 'chat:completion', {'content': 'B so far'});
            if (storeRejects) await rejectStoppedAnswers(a, b);

            // Another writer holds the chat, so the stopped answers cannot be
            // stored yet: nothing may be admitted, and neither answer is finished.
            final writer = Completer<void>();
            unawaited(
              container
                  .read(chatLocksProvider)
                  .runExclusive(serverId, () => writer.future),
            );
            final sending = queue.sendNow(second.id);
            await until(() => api.stoppedChats.isNotEmpty);
            await Future<void>.delayed(const Duration(milliseconds: 20));
            check(api.requests).length.equals(1);
            check(container.read(chatDraftQueueProvider).single.drafts).length
                .equals(2);
            for (final id in [a, b]) {
              check((await storedAnswer(serverId, id))['done']).not(
                (it) => it.equals(true),
              );
            }

            writer.complete();
            if (storeRejects) {
              check(await sending).equals(ChatDraftSendNowOutcome.stopFailed);
              await Future<void>.delayed(const Duration(milliseconds: 50));
              // Nothing was admitted and both drafts wait for a retry.
              check(api.requests).length.equals(1);
              check(
                (await userTurns(serverId)).map((row) => row.content),
              ).deepEquals(['compare these']);
              final waiting = container.read(chatDraftQueueProvider).single;
              check(waiting.drafts.map((d) => d.text)).deepEquals([
                'first',
                'second',
              ]);
              check(waiting.admissionFailed).isTrue();
              for (final id in [a, b]) {
                check((await storedAnswer(serverId, id))['done']).not(
                  (it) => it.equals(true),
                );
              }
              return;
            }
            check(await sending).equals(ChatDraftSendNowOutcome.admitted);
            await until(() => api.requests.length == 2);

            // Exactly one request, for the chosen draft; the other stays queued.
            await Future<void>.delayed(Duration.zero);
            check(api.requests).length.equals(2);
            check(api.stoppedChats.toSet()).deepEquals({serverId});
            check(
              (await userTurns(serverId)).map((row) => row.content),
            ).deepEquals(['compare these', 'second']);
            check(
              container
                  .read(chatDraftQueueProvider)
                  .single
                  .drafts
                  .map((d) => d.text),
            ).deepEquals(['first']);

            await expectStoppedAnswer(
              serverId,
              id: a,
              content: 'A so far',
              slot: 0,
              taskId: 'task-0',
            );
            await expectStoppedAnswer(
              serverId,
              id: b,
              content: 'B so far',
              slot: 1,
              taskId: 'task-1',
            );
            final group = await reopened(serverId, {a, b});
            check(group.shown.isStreaming).isFalse();
            check(group.shown.metadata?[kMessageUnfinishedAnswersMetadataKey])
                .isNull();
            check(group.contents).deepEquals({a: 'A so far', b: 'B so far'});
          },
        );
    }

    /// Send now stops a comparison with two drafts queued while the store
    /// rejects the stopped answers: the server's tasks are stopped, nothing is
    /// admitted and both drafts wait, with the answers still stored as running.
    Future<
      ({
        _FanOutApi api,
        _GroupSocket socket,
        FakeSyncApiClient client,
        ProviderContainer container,
        String serverId,
        String a,
        String b,
        ChatDraftQueueController queue,
        QueuedChatDraft second,
        Future<void> Function() lift,
      })
    >
    stopRejectedByStore({bool rotatableSignIn = false}) async {
      final (:api, :socket, :client, :container, :serverId, :a, :b) =
          await startComparison(rotatableSignIn: rotatableSignIn);
      final queue = container.read(chatDraftQueueProvider.notifier);
      queue.enqueue('first');
      final second = queue.enqueue('second')!;
      socket.deliver(a, 'chat:completion', {'content': 'A so far'});
      socket.deliver(b, 'chat:completion', {'content': 'B so far'});
      final lift = await rejectStoppedAnswers(a, b);
      check(await queue.sendNow(second.id)).equals(
        ChatDraftSendNowOutcome.stopFailed,
      );
      check(api.requests).length.equals(1);
      check(container.read(chatDraftQueueProvider).single.drafts).length
          .equals(2);
      for (final id in [a, b]) {
        check((await storedAnswer(serverId, id))['done']).not(
          (it) => it.equals(true),
        );
      }
      return (
        api: api,
        socket: socket,
        client: client,
        container: container,
        serverId: serverId,
        a: a,
        b: b,
        queue: queue,
        second: second,
        lift: lift,
      );
    }

    // A stop whose answers could not be stored owes them to the next queued
    // admission, however it is retried: that admission stores them first and
    // only then sends, and a retry the store still rejects sends nothing.
    for (final combined in [false, true]) {
      test(
        combined
            ? 'a combined retry after a rejected store stores the stopped '
                  'answers before it admits both drafts'
            : 'a Send now retry after a rejected store stores the stopped '
                  'answers before it admits the chosen draft',
        () async {
          final (
            :api,
            :socket,
            :client,
            :container,
            :serverId,
            :a,
            :b,
            :queue,
            :second,
            :lift,
          ) = await stopRejectedByStore();
          Future<ChatDraftSendNowOutcome?> retry() async {
            if (!combined) return queue.sendNow(second.id);
            queue.retryAdmission();
            return null;
          }

          // The store still rejects them: nothing is admitted and nothing is
          // lost from the queue.
          final refused = await retry();
          if (combined) {
            await until(
              () => container.read(chatDraftQueueProvider).single.admissionFailed,
            );
          } else {
            check(refused).equals(ChatDraftSendNowOutcome.admissionFailed);
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          check(api.requests).length.equals(1);
          check((await userTurns(serverId)).map((row) => row.content))
              .deepEquals(['compare these']);
          final waiting = container.read(chatDraftQueueProvider).single;
          check(waiting.drafts.map((d) => d.text)).deepEquals([
            'first',
            'second',
          ]);
          check(waiting.admissionFailed).isTrue();
          check(waiting.phase).equals(ChatDraftQueuePhase.idle);
          check(waiting.frozenDraftIds).isEmpty();
          for (final id in [a, b]) {
            check((await storedAnswer(serverId, id))['done']).not(
              (it) => it.equals(true),
            );
          }

          // Once the store takes them, the retry stores them and sends exactly
          // one next turn.
          await lift();
          final admitted = await retry();
          if (!combined) {
            check(admitted).equals(ChatDraftSendNowOutcome.admitted);
          }
          await until(() => api.requests.length == 2);
          await until(
            () => container
                .read(chatDraftQueueProvider)
                .every((held) => held.frozenDraftIds.isEmpty),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          check(api.requests).length.equals(2);
          check((await userTurns(serverId)).map((row) => row.content))
              .deepEquals([
                'compare these',
                combined ? 'first\n\nsecond' : 'second',
              ]);
          final remaining = container.read(chatDraftQueueProvider);
          if (combined) {
            check(remaining).isEmpty();
          } else {
            check(remaining.single.drafts.map((d) => d.text)).deepEquals([
              'first',
            ]);
          }

          // The answers keep the text they were stopped with, in the store, on
          // the server's copy and after a pull of it.
          await container.read(syncEngineProvider.notifier).pullChatNow(serverId);
          for (var i = 0; i < 10; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          await expectStoppedAnswer(
            serverId,
            id: a,
            content: 'A so far',
            slot: 0,
            taskId: 'task-0',
          );
          await expectStoppedAnswer(
            serverId,
            id: b,
            content: 'B so far',
            slot: 1,
            taskId: 'task-1',
          );
          final group = await reopened(serverId, {a, b});
          check(group.shown.isStreaming).isFalse();
          check(group.contents).deepEquals({a: 'A so far', b: 'B so far'});
        },
      );
    }

    // The retry waits for the store, so the conversation or account it was
    // asked under can be gone when the write ends. The write is the old
    // owner's and lands in the old store; the old drafts are not sent for the
    // new owner and the new screen is not touched.
    for (final signIn in [false, true]) {
      test(
        signIn
            ? 'a new sign-in while a retry stores the stopped answers admits '
                  'nothing and leaves the drafts queued'
            : 'opening another chat while a retry stores the stopped answers '
                  'admits nothing and leaves the screen to that chat',
        () async {
          final (
            :api,
            :socket,
            :client,
            :container,
            :serverId,
            :a,
            :b,
            :queue,
            :second,
            :lift,
          ) = await stopRejectedByStore(rotatableSignIn: true);
          await lift();
          // Another writer holds the chat, so the retry waits for the store.
          final writer = Completer<void>();
          unawaited(
            container
                .read(chatLocksProvider)
                .runExclusive(serverId, () => writer.future),
          );
          final retrying = queue.sendNow(second.id);
          await until(
            () =>
                container.read(chatDraftQueueProvider).single.phase ==
                ChatDraftQueuePhase.admitting,
          );
          final other = [_user('other-user', 'hello')];
          if (signIn) {
            container.read(_signInEpochProvider.notifier).rotate();
          } else {
            container
                .read(activeConversationProvider.notifier)
                .set(
                  _conversation('other-chat', other, ChatStorageKind.openWebUi),
                );
          }
          writer.complete();
          check(await retrying).equals(ChatDraftSendNowOutcome.changed);
          await Future<void>.delayed(const Duration(milliseconds: 50));

          // Nothing was sent and the old drafts wait for their own owner.
          check(api.requests).length.equals(1);
          check((await userTurns(serverId)).map((row) => row.content))
              .deepEquals(['compare these']);
          final waiting = container.read(chatDraftQueueProvider).single;
          check(waiting.drafts.map((d) => d.text)).deepEquals([
            'first',
            'second',
          ]);
          check(waiting.phase).equals(ChatDraftQueuePhase.idle);
          check(waiting.frozenDraftIds).isEmpty();
          // Still as the failed stop left it: waiting for the user's retry.
          check(waiting.admissionFailed).isTrue();
          // The answers were stored into the store they were stopped under.
          await expectStoppedAnswer(
            serverId,
            id: a,
            content: 'A so far',
            slot: 0,
            taskId: 'task-0',
          );
          await expectStoppedAnswer(
            serverId,
            id: b,
            content: 'B so far',
            slot: 1,
            taskId: 'task-1',
          );
          if (!signIn) {
            // What is on screen is the chat the user opened, with no row of
            // the old chat's turn and no row stored for it.
            check(container.read(activeConversationProvider)!.id).equals(
              'other-chat',
            );
            check(
              container.read(chatMessagesProvider).map((message) => message.id),
            ).deepEquals(['other-user']);
            check(await db.messagesDao.getForChat('other-chat')).isEmpty();
          }
        },
      );
    }

    test('stopping the whole turn with nothing queued stores both answers as '
        'finished and leaves the shown answer shown', () async {
      final (:api, :socket, :client, :container, :serverId, :a, :b) =
          await startComparison();
      socket.deliver(a, 'chat:completion', {'content': 'A so far'});
      socket.deliver(b, 'chat:completion', {'content': 'B so far'});
      check((await db.chatsDao.getChat(serverId))!.currentMessageId).equals(a);
      // A field this build does not model, as a newer server may have sent it.
      final stored = (await db.messagesDao.getMessage(serverId, b))!;
      await db.messagesDao.upsertLocalEcho(
        MessageRowData(
          id: stored.id,
          chatId: serverId,
          parentId: stored.parentId,
          role: stored.role,
          content: stored.content,
          model: stored.model,
          createdAt: stored.createdAt,
          orderIndex: stored.orderIndex,
          payload: <String, dynamic>{
            ...jsonDecode(stored.payload) as Map<String, dynamic>,
            'futureField': {'kept': true},
          },
        ),
      );

      container.read(stopGenerationProvider)();
      await until(() => api.stoppedChats.isNotEmpty);
      await until(() => !container.read(isChatStreamingProvider));
      // The write happens under the chat lock, after the screen has settled.
      for (var i = 0; i < 200; i++) {
        if ((await storedAnswer(serverId, a))['done'] == true &&
            (await storedAnswer(serverId, b))['done'] == true) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      await expectStoppedAnswer(
        serverId,
        id: a,
        content: 'A so far',
        slot: 0,
        taskId: 'task-0',
      );
      await expectStoppedAnswer(
        serverId,
        id: b,
        content: 'B so far',
        slot: 1,
        taskId: 'task-1',
      );
      check((await storedAnswer(serverId, b))['futureField'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'kept': true});
      // Settling the sibling did not move the branch to it, and nothing else
      // in the chat was touched.
      check((await db.chatsDao.getChat(serverId))!.currentMessageId).equals(a);
      check((await db.messagesDao.getForChat(serverId)).map((row) => row.id))
          .unorderedEquals([(await userTurns(serverId)).single.id, a, b]);
      check(api.requests).length.equals(1);
      // The server's own copy still holds the running checkpoint it kept. The
      // update op carries the finished state to it, and a pull of it does not
      // bring the stopped answers back to life.
      Map<String, dynamic> serverAnswer(String id) =>
          (((client.server.getChatById(serverId)!['chat']
                      as Map<String, dynamic>)['history']
                  as Map<String, dynamic>)['messages']
              as Map<String, dynamic>)[id] as Map<String, dynamic>;
      for (var i = 0; i < 200; i++) {
        if (serverAnswer(a)['done'] == true && serverAnswer(b)['done'] == true) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      for (final id in [a, b]) {
        check(serverAnswer(id)['done']).equals(true);
        check(serverAnswer(id)['isStreaming']).not((it) => it.equals(true));
      }
      await container.read(syncEngineProvider.notifier).pullChatNow(serverId);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      for (final entry in {a: ('A so far', 0, 'task-0'), b: ('B so far', 1, 'task-1')}
          .entries) {
        await expectStoppedAnswer(
          serverId,
          id: entry.key,
          content: entry.value.$1,
          slot: entry.value.$2,
          taskId: entry.value.$3,
        );
      }
      final group = await reopened(serverId, {a, b});
      check(group.shown.id).equals(a);
      check(group.shown.isStreaming).isFalse();
      check(group.shown.metadata?[kMessageUnfinishedAnswersMetadataKey])
          .isNull();
      check(group.contents).deepEquals({a: 'A so far', b: 'B so far'});
    });

    test('an administrator stopping one answer has it stored as finished at '
        'once, and it stays so when its sibling and the next turn complete',
        () async {
      final (:api, :socket, :client, :container, :serverId, :a, :b) =
          await startComparison(account: _admin);
      final queue = container.read(chatDraftQueueProvider.notifier);
      queue.enqueue('first');
      socket.deliver(a, 'chat:completion', {'content': 'A so far'});
      socket.deliver(b, 'chat:completion', {'content': 'B so far'});

      // The answer that is not shown is stopped; the shown one keeps running.
      check(await container.read(stopComparisonAnswerProvider)(b)).equals(
        ComparisonAnswerStop.stopped,
      );
      check(api.stoppedTasks).deepEquals(['task-1']);
      await expectStoppedAnswer(
        serverId,
        id: b,
        content: 'B so far',
        slot: 1,
        taskId: 'task-1',
      );
      check((await storedAnswer(serverId, a))['done']).not(
        (it) => it.equals(true),
      );
      // Stopping it did not move the chat's shown answer, and a pull of the
      // server's copy, which still holds the checkpoint it kept, leaves the
      // stopped answer finished.
      check((await db.chatsDao.getChat(serverId))!.currentMessageId).equals(a);
      await container.read(syncEngineProvider.notifier).pullChatNow(serverId);
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await expectStoppedAnswer(
        serverId,
        id: b,
        content: 'B so far',
        slot: 1,
        taskId: 'task-1',
      );
      check((await db.chatsDao.getChat(serverId))!.currentMessageId).equals(a);

      // The sibling finishes, which sends the queued draft once.
      socket.deliver(a, 'chat:completion', {'content': 'A final', 'done': true});
      await until(() => api.requests.length == 2);
      await until(() => container.read(chatDraftQueueProvider).isEmpty);
      socket.deliver(
        api.requests.last.responseMessageId!,
        'chat:completion',
        {'content': 'next', 'done': true},
      );
      await until(
        () => container
            .read(chatMessagesProvider)
            .any((message) => message.content == 'next'),
      );
      await Future<void>.delayed(Duration.zero);

      await expectStoppedAnswer(
        serverId,
        id: b,
        content: 'B so far',
        slot: 1,
        taskId: 'task-1',
      );
      // The sibling's own completion belongs to the server's copy; the stopped
      // answer is not reported as running because of it, and keeps its text.
      final group = await reopened(serverId, {a, b});
      final unfinished =
          group.shown.metadata?[kMessageUnfinishedAnswersMetadataKey];
      check(unfinished is List ? unfinished : const <Object?>[]).not(
        (it) => it.contains(b),
      );
      check(group.contents[b]).equals('B so far');
    });

    test('leaving while the chat is created neither sends the group again nor '
        'fails tasks the server still runs, and the new screen is untouched',
        () async {
      final (:api, :socket, :client, :container) = await openDraft();
      api.activeTaskIds = const ['task-0', 'task-1'];
      final releaseCreate = Completer<void>();
      client.createChatGate = releaseCreate.future;

      final sending = durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      await until(() => client.createChatStarts.isNotEmpty);
      final localId = container.read(activeConversationProvider)!.id;
      final ids = [
        for (final row in await db.messagesDao.getForChat(localId))
          if (row.role == 'assistant') row.id,
      ];

      // The user opens another chat while the first one is still being created.
      final other = [_user('other-user', 'hello')];
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('other-chat', other, ChatStorageKind.openWebUi));
      releaseCreate.complete();
      await sending;
      await until(() => api.requests.isNotEmpty);
      await Future<void>.delayed(Duration.zero);

      // The accepted group is sent once and its answers are left as the server
      // has them: running, not failed because a short wait found nothing yet.
      check(api.requests).length.equals(1);
      check(api.stoppedTasks).isEmpty();
      // The rows moved to the chat's server id when it was created.
      final serverId = (await db.select(db.chats).get()).single.id;
      check(serverId).not((it) => it.equals(localId));
      check(ids).length.equals(2);
      for (final id in ids) {
        final row = await db.messagesDao.getMessage(serverId, id);
        final payload = jsonDecode(row!.payload) as Map<String, dynamic>;
        check(payload['error']).isNull();
        check(payload['done']).not((it) => it.equals(true));
      }

      // What the user is looking at is the chat they opened.
      check(container.read(activeConversationProvider)!.id).equals('other-chat');
      check(
        container.read(chatMessagesProvider).map((message) => message.id),
      ).deepEquals(['other-user']);
    });

    test('a new sign-in while the server is asked for the chat\'s tasks leaves '
        'the old account\'s unfinished answers as they were', () async {
      final (:api, :socket, :client, :container) = await openDraft(
        rotatableSignIn: true,
      );
      // The server's list is held at the moment recovery asks whether it lost
      // the work, and says nothing is running once it answers.
      final taskList = Completer<List<String>>();
      api.holdTaskList = taskList;
      final releaseCreate = Completer<void>();
      client.createChatGate = releaseCreate.future;

      final sending = durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      await until(() => client.createChatStarts.isNotEmpty);
      final localId = container.read(activeConversationProvider)!.id;
      final ids = [
        for (final row in await db.messagesDao.getForChat(localId))
          if (row.role == 'assistant') row.id,
      ];
      final other = [_user('other-user', 'hello')];
      container
          .read(activeConversationProvider.notifier)
          .set(_conversation('other-chat', other, ChatStorageKind.openWebUi));
      releaseCreate.complete();
      await until(() => api.taskListEntered.isCompleted);

      // Another sign-in replaces the session while the answer is pending.
      container.read(_signInEpochProvider.notifier).rotate();
      taskList.complete(const []);
      await sending;
      await Future<void>.delayed(Duration.zero);

      // The work belongs to the account that sent it: no verdict is written on
      // an empty list read for a session that is gone, and nothing is resent.
      check(api.requests).length.equals(1);
      check(api.stoppedTasks).isEmpty();
      final serverId = (await db.select(db.chats).get()).single.id;
      check(ids).length.equals(2);
      for (final id in ids) {
        final row = await db.messagesDao.getMessage(serverId, id);
        final payload = jsonDecode(row!.payload) as Map<String, dynamic>;
        check(payload['error']).isNull();
        check(payload['done']).not((it) => it.equals(true));
      }
      check(container.read(activeConversationProvider)!.id).equals('other-chat');
    });

    test('answers the stored copy has already settled are shown in its form, '
        'not held as running', () async {
      final (:api, :socket, :client, :container) = await openDraft();
      final holdResponse = Completer<void>();
      api.holdResponse = holdResponse;
      final sending = durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      await until(() => api.requests.isNotEmpty);
      final serverId = container.read(activeConversationProvider)!.id;

      // Admitted and sent, but not yet bound: the server's copy of the chat now
      // holds both answers, as a pull would bring it.
      for (final row in await db.messagesDao.getForChat(serverId)) {
        if (row.role != 'assistant') continue;
        final text = 'landed ${row.orderIndex}';
        await db.messagesDao.upsertLocalEcho(
          MessageRowData(
            id: row.id,
            chatId: serverId,
            parentId: row.parentId,
            role: 'assistant',
            content: text,
            model: row.model,
            createdAt: row.createdAt,
            orderIndex: row.orderIndex,
            payload: <String, dynamic>{
              ...jsonDecode(row.payload) as Map<String, dynamic>,
              'content': text,
              'isStreaming': false,
              'done': true,
            },
          ),
        );
      }
      await until(
        () => container
            .read(chatMessagesProvider)
            .any((message) => message.content == 'landed 1'),
      );

      final shown = container
          .read(chatMessagesProvider)
          .singleWhere((message) => message.role == 'assistant');
      check(shown.content).equals('landed 1');
      check(shown.isStreaming).isFalse();
      check(shown.versions.map((version) => version.content)).deepEquals([
        'landed 2',
      ]);

      holdResponse.complete();
      await sending;
    });

    test('answers the server holds only part of before they are bound stay '
        'live, each with its own task', () async {
      final (:api, :socket, :client, :container) = await openDraft(
        account: _admin,
      );
      final holdResponse = Completer<void>();
      api.holdResponse = holdResponse;
      final sending = durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      await until(() => api.requests.isNotEmpty);
      final serverId = container.read(activeConversationProvider)!.id;
      socket.chatId = serverId;
      final handles = api.requests.single.messageIds!;

      // Admitted and sent but not yet bound, the server has begun both answers
      // without finishing either, and a real pull brings its copy in.
      final stored = client.server.getChatById(serverId)!;
      final blob = stored['chat'] as Map<String, dynamic>;
      final messages =
          (blob['history'] as Map<String, dynamic>)['messages']
              as Map<String, dynamic>;
      for (final handle in handles) {
        (messages[handle.messageId] as Map<String, dynamic>)
          ..['content'] = 'partial ${handle.messageId}'
          ..['done'] = false;
      }
      client.server.updateChat(serverId, blob);
      await container.read(syncEngineProvider.notifier).pullChatNow(serverId);
      await until(
        () => container
            .read(chatMessagesProvider)
            .any((message) => message.content.startsWith('partial ')),
      );

      holdResponse.complete();
      await sending;

      // Partial text is not a finished answer: both are still their own live
      // message, in their own column, and each took the task started for it.
      final a = handles.first.messageId;
      final b = handles.last.messageId;
      check(
        container
            .read(chatMessagesProvider)
            .where((message) => message.role == 'assistant')
            .map((message) => message.id),
      ).deepEquals([a, b]);
      for (final id in [a, b]) {
        check(answer(container, id).isStreaming).isTrue();
        check(answer(container, id).versions).isEmpty();
      }
      check(answer(container, a).modelSlot).equals(0);
      check(answer(container, b).modelSlot).equals(1);
      check(answer(container, a).metadata?['taskId']).equals('task-0');
      check(answer(container, b).metadata?['taskId']).equals('task-1');

      // Each answer takes its own events and its own Stop.
      final before = answer(container, a).content;
      socket.deliver(b, 'chat:completion', {'content': 'B so far'});
      check(answer(container, a).content).equals(before);
      check(answer(container, b).content).equals('B so far');
      await container.read(stopComparisonAnswerProvider)(b);
      check(api.stoppedTasks).deepEquals(['task-1']);
      check(answer(container, a).isStreaming).isTrue();
      check(client.createChatCalls).equals(1);
      check(api.requests).length.equals(1);
    });

    test('answers the server has since finished are not kept live by the '
        'unfinished list this app saved back to it', () async {
      final (:api, :socket, :client, :container) = await openDraft();
      final holdResponse = Completer<void>();
      api.holdResponse = holdResponse;
      final sending = durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      await until(() => api.requests.isNotEmpty);
      final serverId = container.read(activeConversationProvider)!.id;
      socket.chatId = serverId;
      final handles = api.requests.single.messageIds!;
      final a = handles.first.messageId;
      final b = handles.last.messageId;

      final stored = client.server.getChatById(serverId)!;
      final blob = stored['chat'] as Map<String, dynamic>;
      final messages =
          (blob['history'] as Map<String, dynamic>)['messages']
              as Map<String, dynamic>;
      Map<String, dynamic> serverAnswer(String id) =>
          messages[id] as Map<String, dynamic>;
      Future<void> pull() async {
        client.server.updateChat(serverId, blob);
        await container.read(syncEngineProvider.notifier).pullChatNow(serverId);
      }

      // The server has begun both answers, and a real pull brings them in.
      for (final id in [a, b]) {
        serverAnswer(id)
          ..['content'] = 'partial $id'
          ..['done'] = false;
      }
      await pull();
      await until(
        () => container
            .read(chatMessagesProvider)
            .any((message) => message.content.startsWith('partial ')),
      );

      // What this app writes back for the answer it shows is exactly what the
      // sync outbox would push, so it is what the server hands back later.
      final echoed =
          localEchoRowForMessage(
                serverId,
                container
                    .read(chatMessagesProvider)
                    .firstWhere((message) => message.role == 'assistant'),
              ).payload['metadata']
              as Map<String, dynamic>;
      check(echoed[kMessageUnfinishedAnswersMetadataKey]).isNotNull();

      // The server then finishes both answers and returns that metadata.
      for (final id in [a, b]) {
        serverAnswer(id)
          ..['content'] = 'final $id'
          ..['done'] = true
          ..['isStreaming'] = false;
      }
      serverAnswer(a)['metadata'] = echoed;
      await pull();
      await until(
        () => container
            .read(chatMessagesProvider)
            .any((message) => message.content == 'final $a'),
      );

      // Finished answers are the ordinary version projection again: one shown
      // answer, its sibling a version, neither live and neither stoppable.
      final assistants = container
          .read(chatMessagesProvider)
          .where((message) => message.role == 'assistant')
          .toList();
      check(assistants.map((message) => message.id)).deepEquals([a]);
      final shown = assistants.single;
      check(shown.content).equals('final $a');
      check(shown.isStreaming).isFalse();
      check(shown.modelSlot).equals(0);
      check(shown.metadata?[kMessageUnfinishedAnswersMetadataKey]).isNull();
      check(shown.versions.map((version) => version.id)).deepEquals([b]);
      check(shown.versions.single.content).equals('final $b');
      check(shown.versions.single.modelIdx).equals(1);
      check(api.stoppedTasks).isEmpty();

      // The request's receipt arrives only now, after the server finished. The
      // answers it names stay finished: no spinner, no Stop, no task bound.
      holdResponse.complete();
      await sending;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final afterReceipt = container
          .read(chatMessagesProvider)
          .where((message) => message.role == 'assistant')
          .toList();
      check(afterReceipt.map((message) => message.id)).deepEquals([a]);
      final settled = afterReceipt.single;
      check(settled.isStreaming).isFalse();
      check(settled.content).equals('final $a');
      check(settled.modelSlot).equals(0);
      check(settled.metadata?['taskId']).isNull();
      check(settled.versions.map((version) => version.id)).deepEquals([b]);
      check(settled.versions.single.content).equals('final $b');
      check(settled.versions.single.modelIdx).equals(1);
      for (final id in [a, b]) {
        final payload =
            jsonDecode((await db.messagesDao.getMessage(serverId, id))!.payload)
                as Map<String, dynamic>;
        check(payload['done']).equals(true);
        check(payload['isStreaming']).not((it) => it.equals(true));
        check(payload['content']).equals('final $id');
      }
      check(api.stoppedTasks).isEmpty();
      check(api.stoppedChats).isEmpty();
      check(client.createChatCalls).equals(1);
      check(api.requests).length.equals(1);
    });

    test('a receipt that arrives after only some answers finished binds the '
        'rest, each to its own task', () async {
      final (:api, :socket, :client, :container) = await openDraft(
        account: _admin,
      );
      final holdResponse = Completer<void>();
      api.holdResponse = holdResponse;
      final sending = durableCompareSend(
        container,
        'compare these',
        null,
        models: const [duplicate, duplicate],
      );
      await until(() => api.requests.isNotEmpty);
      final serverId = container.read(activeConversationProvider)!.id;
      socket.chatId = serverId;
      final handles = api.requests.single.messageIds!;
      final a = handles.first.messageId;
      final b = handles.last.messageId;

      // The server has finished the first answer and is still on the second.
      final stored = client.server.getChatById(serverId)!;
      final blob = stored['chat'] as Map<String, dynamic>;
      final messages =
          (blob['history'] as Map<String, dynamic>)['messages']
              as Map<String, dynamic>;
      (messages[a] as Map<String, dynamic>)
        ..['content'] = 'final $a'
        ..['done'] = true
        ..['isStreaming'] = false;
      (messages[b] as Map<String, dynamic>)
        ..['content'] = 'partial $b'
        ..['done'] = false;
      client.server.updateChat(serverId, blob);
      await container.read(syncEngineProvider.notifier).pullChatNow(serverId);
      await until(
        () => container
            .read(chatMessagesProvider)
            .any((message) => message.content == 'final $a'),
      );

      holdResponse.complete();
      await sending;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // The finished answer stays finished and unbound; the other one is live,
      // on the task the server started for its position.
      check(
        container
            .read(chatMessagesProvider)
            .where((message) => message.role == 'assistant')
            .map((message) => message.id),
      ).deepEquals([a, b]);
      check(answer(container, a).isStreaming).isFalse();
      check(answer(container, a).content).equals('final $a');
      check(answer(container, a).metadata?['taskId']).isNull();
      check(answer(container, a).error).isNull();
      check(answer(container, b).isStreaming).isTrue();
      check(answer(container, b).modelSlot).equals(1);
      check(answer(container, b).metadata?['taskId']).equals('task-1');
      final doneRow =
          jsonDecode((await db.messagesDao.getMessage(serverId, a))!.payload)
              as Map<String, dynamic>;
      check(doneRow['done']).equals(true);
      check(doneRow['isStreaming']).not((it) => it.equals(true));

      // Events and Stop reach only the answer that is still running.
      socket.deliver(b, 'chat:completion', {'content': 'B so far'});
      check(answer(container, b).content).equals('B so far');
      check(answer(container, a).content).equals('final $a');
      await container.read(stopComparisonAnswerProvider)(b);
      check(api.stoppedTasks).deepEquals(['task-1']);
      check(answer(container, a).isStreaming).isFalse();
      check(client.createChatCalls).equals(1);
      check(api.requests).length.equals(1);
    });
  });
}

/// A selection that is on regardless of what the composer would have allowed,
/// to prove the request itself refuses what the server does not support.
class _AlwaysSelected extends CodeInterpreterEnabledNotifier {
  @override
  bool build() => true;
}

/// A loopback host that publishes a one-operation OpenAPI document and records
/// the credential each request carried.
final class _OpenApiHost {
  _OpenApiHost._(this._server, this.title) {
    _server.listen((request) {
      authorizations.add(request.headers.value('authorization'));
      request.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode(<String, dynamic>{
            'openapi': '3.0.0',
            'info': <String, dynamic>{'title': title, 'version': '1'},
            'paths': <String, dynamic>{
              '/ping': <String, dynamic>{
                'get': <String, dynamic>{
                  'operationId': 'ping',
                  'summary': 'Ping',
                  'responses': <String, dynamic>{
                    '200': <String, dynamic>{'description': 'ok'},
                  },
                },
              },
            },
          }),
        );
      request.response.close();
    });
  }

  static Future<_OpenApiHost> start(String title) async => _OpenApiHost._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    title,
  );

  final HttpServer _server;
  final String title;
  final List<String?> authorizations = <String?>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);
}


/// One completion request as the chat providers sent it.
class _FanOutRequest {
  _FanOutRequest({
    required this.messages,
    required this.model,
    required this.responseMessageId,
    required this.messageIds,
    required this.userMessage,
    required this.chatParams,
  });

  final List<Map<String, dynamic>> messages;
  final String model;
  final String? responseMessageId;
  final List<ChatCompletionTarget>? messageIds;
  final Map<String, dynamic>? userMessage;
  final Map<String, dynamic>? chatParams;
}

/// An API double for a server that fans one request out to several tasks (or,
/// for an old server, answers one response synchronously).
class _FanOutApi extends ApiService implements _AssistantIdSource {
  _FanOutApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'fan-out',
          name: 'Fan out',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  final List<_FanOutRequest> requests = [];
  final List<String> stoppedTasks = [];
  final List<String> stoppedChats = [];
  bool answerSynchronously = false;

  /// When set, the completion request is accepted only once this completes: the
  /// window in which the account can change under a delayed response.
  Completer<void>? holdResponse;

  /// What the merge endpoint is asked, and how it answers.
  final List<({String model, String prompt, List<String> responses})> merges =
      [];
  StreamController<OpenWebUIStreamUpdate>? mergeUpdates;
  bool mergeEndpointMissing = false;

  /// When set, the merge endpoint answers with its headers only once this
  /// completes, and [mergeEntered] marks the wait.
  Completer<void>? holdMergeHeaders;
  final mergeEntered = Completer<void>();

  /// When set, the merge endpoint refuses once its headers would have arrived.
  MoaCompletionFailed? mergeFailure;
  int mergeCancels = 0;

  @override
  String? get assistantMessageId => requests.lastOrNull?.responseMessageId;

  /// When set, the account's settings are answered only once this completes,
  /// and [settingsEntered] marks the wait: the window in which a draft can move
  /// on while its admission is still being prepared.
  Completer<void>? holdSettings;
  final settingsEntered = Completer<void>();

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async {
    final hold = holdSettings;
    if (hold != null) {
      if (!settingsEntered.isCompleted) settingsEntered.complete();
      await hold.future;
    }
    return const <String, dynamic>{};
  }

  /// The tasks the server reports as still running for a chat.
  List<String> activeTaskIds = const [];

  /// When set, the task list is answered only once this completes, and
  /// [taskListEntered] marks the wait: the window in which the account can
  /// change under a recovery that is deciding whether the server lost its work.
  Completer<List<String>>? holdTaskList;
  final taskListEntered = Completer<void>();

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async {
    final hold = holdTaskList;
    if (hold == null) return activeTaskIds;
    if (!taskListEntered.isCompleted) taskListEntered.complete();
    return hold.future;
  }

  @override
  Future<void> stopTask(String taskId) async {
    stoppedTasks.add(taskId);
    await holdStop?.future;
    final failure = stopFailure;
    if (failure != null) throw failure;
  }

  /// When set, a task stop is acknowledged only once this completes.
  Completer<void>? holdStop;

  /// When set, the server refuses every task stop with this.
  Object? stopFailure;

  @override
  Future<void> stopTasksByChat(String chatId) async =>
      stoppedChats.add(chatId);

  @override
  Future<MoaCompletion> generateMoaCompletion({
    required String model,
    required String prompt,
    required List<String> responses,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    merges.add((model: model, prompt: prompt, responses: responses));
    if (mergeEndpointMissing) throw const MoaCompletionUnavailable(404);
    if (!mergeEntered.isCompleted) mergeEntered.complete();
    await holdMergeHeaders?.future;
    final failure = mergeFailure;
    if (failure != null) throw failure;
    final updates = StreamController<OpenWebUIStreamUpdate>();
    mergeUpdates = updates;
    return MoaCompletion(
      updates: updates.stream,
      cancel: () async {
        mergeCancels++;
        if (!updates.isClosed) {
          unawaited(updates.close());
        }
      },
    );
  }

  @override
  Future<Conversation> getConversation(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async => throw StateError('offline');

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
    requests.add(
      _FanOutRequest(
        messages: [
          for (final message in messages) Map<String, dynamic>.of(message),
        ],
        model: model,
        responseMessageId: responseMessageId,
        messageIds: messageIds,
        userMessage: userMessage == null
            ? null
            : Map<String, dynamic>.of(userMessage),
        chatParams: chatParams == null
            ? null
            : Map<String, dynamic>.of(chatParams),
      ),
    );
    await holdResponse?.future;
    if (answerSynchronously) {
      return ChatCompletionSession.jsonCompletion(
        messageId: responseMessageId!,
        conversationId: conversationId,
        jsonPayload: const <String, dynamic>{
          'choices': <Map<String, dynamic>>[
            <String, dynamic>{
              'message': <String, dynamic>{'content': 'one answer'},
            },
          ],
        },
      );
    }
    final count = messageIds?.length ?? 1;
    final taskIds = [for (var i = 0; i < count; i++) 'task-$i'];
    return ChatCompletionSession.taskSocket(
      messageId: responseMessageId!,
      sessionId: sessionIdOverride,
      conversationId: conversationId,
      taskId: taskIds.first,
      taskIds: taskIds,
    );
  }
}

/// A connected socket that hands every event to every handler of its chat, as
/// the real service does for handlers registered by conversation: it is the
/// streams themselves that must tell the answers of one chat apart.
class _GroupSocket extends SocketService {
  _GroupSocket({required this.chatId, bool connected = true})
    : _connected = connected,
      super(
        serverConfig: const ServerConfig(
          id: 'fan-out',
          name: 'Fan out',
          url: 'https://example.com',
        ),
      );

  /// The chat the events are for. A draft's chat is given its server id while
  /// the answers run, so a test moves this with it.
  String chatId;
  final bool _connected;
  final List<({String? chatId, String? messageId, SocketChatEventHandler handler})>
  handlers = [];

  @override
  bool get isConnected => _connected;

  @override
  String? get sessionId => _connected ? 'socket-a' : null;

  @override
  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 2),
  }) async => _connected;

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    bool keepsAliveInBackground = false,
    SocketReplayGapCallback? onReplayGap,
    required SocketChatEventHandler handler,
  }) {
    final entry = (
      chatId: conversationId,
      messageId: messageId,
      handler: handler,
    );
    handlers.add(entry);
    return SocketEventSubscription(() => handlers.remove(entry));
  }

  @override
  SocketEventSubscription addChannelEventHandler({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
    required SocketChannelEventHandler handler,
  }) => SocketEventSubscription(() {});

  void deliver(String messageId, String type, Map<String, dynamic> payload) {
    final event = <String, dynamic>{
      'chat_id': chatId,
      'message_id': messageId,
      'session_id': 'socket-a',
      'data': <String, dynamic>{'type': type, 'data': payload},
    };
    for (final entry in List.of(handlers)) {
      if (entry.chatId == chatId || entry.messageId == messageId) {
        entry.handler(event, null);
      }
    }
  }
}

/// A sync engine that never lands a pull and never drains, so what the chat
/// providers wrote stays exactly as admitted.
class _QuietSyncEngine extends _PersistingSyncEngine {
  _QuietSyncEngine(super.db, super.api) : super(landResponse: false);

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {}
}

/// An engine whose outbox drain fails, as an unreachable server or a closed
/// database would after a turn was already committed.
class _ThrowingDrainEngine extends _QuietSyncEngine {
  _ThrowingDrainEngine(super.db, super.api);

  @override
  Future<void> drainNowForDatabase(AppDatabase expectedDatabase) async {
    throw StateError('drain failed');
  }
}

/// The history of a rebuilt blob after a two-answer comparison: one user
/// message that names both answers, and each answer in its own column.
void _expectComparisonHistory(
  Map<String, dynamic> blob,
  List<ChatSendPlaceholderHandle> handles,
) {
  final ids = [for (final handle in handles) handle.assistantMessageId];
  final history = blob['history'] as Map<String, dynamic>;
  check(history['currentId']).equals(ids.first);
  final messages = history['messages'] as Map<String, dynamic>;
  final user = messages[handles.first.userMessageId] as Map<String, dynamic>;
  check(user['childrenIds']).isA<List<Object?>>().deepEquals(ids);
  check(user['models']).isA<List<Object?>>().deepEquals([
    'model-1',
    'model-1',
  ]);
  for (var index = 0; index < ids.length; index++) {
    final answer = messages[ids[index]] as Map<String, dynamic>;
    check(answer['parentId']).equals(handles.first.userMessageId);
    check(answer['modelIdx']).equals(index);
  }
}

/// The models the server lists, without asking one.
class _ListedModels extends Models {
  _ListedModels(this.listed);

  final List<Model> listed;

  @override
  Future<List<Model>> build() async => listed;
}

/// An engine whose pull lands only the listed answers, as a server that has
/// finished some answers of a comparison and not others.
class _PartialLandingEngine extends _QuietSyncEngine {
  _PartialLandingEngine(super.db, super.api);

  List<String> landedIds = const [];

  @override
  Future<Conversation?> pullChatNow(String requestedChatId) async {
    return withChatStorageProvenance(
      Conversation(
        id: requestedChatId,
        title: 'A',
        createdAt: DateTime.utc(2026, 7, 13),
        updatedAt: DateTime.utc(2026, 7, 13),
        messages: [
          for (final id in landedIds)
            ChatMessage(
              id: id,
              role: 'assistant',
              content: 'landed',
              timestamp: DateTime.utc(2026, 7, 13, 0, 0, 2),
              model: 'model-1',
            ),
        ],
      ),
      ChatStorageKind.openWebUi,
    );
  }
}
