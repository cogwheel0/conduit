import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart'
    show
        DioException,
        Headers,
        HttpClientAdapter,
        InterceptorsWrapper,
        RequestOptions,
        Response,
        ResponseBody;
import 'package:fake_async/fake_async.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/chat_completion_transport.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/historical_message_regeneration.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

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
  void cancelActiveMessageStreamPreservingContent() {}

  @override
  void appendToLastMessage(String content) {
    if (state.isEmpty || content.isEmpty) {
      return;
    }

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') {
      return;
    }

    state = [
      ...state.sublist(0, state.length - 1),
      lastMessage.copyWith(content: '${lastMessage.content}$content'),
    ];
  }

  @override
  void bufferLastMessageContent(String content, {bool immediate = true}) {
    replaceLastMessageContent(content);
  }

  @override
  void replaceLastMessageContent(String content) {
    if (state.isEmpty) {
      return;
    }

    final lastMessage = state.last;
    if (lastMessage.role != 'assistant') {
      return;
    }

    state = [
      ...state.sublist(0, state.length - 1),
      lastMessage.copyWith(content: content),
    ];
  }

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
  SocketService? socketService,
  User? user,
}) {
  final container = ProviderContainer(
    overrides: [
      if (user != null) currentUserProvider2.overrideWithValue(user),
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
      socketServiceProvider.overrideWithValue(socketService),
    ],
  );

  container.read(chatMessagesProvider.notifier).setMessages(initialMessages);
  if (initialImageGenerationEnabled) {
    container.read(imageGenerationEnabledProvider.notifier).set(true);
  }

  return container;
}

class _RecordingCompletionApi extends ApiService {
  _RecordingCompletionApi({
    this.settingsGate,
    this.sendGate,
    this.sendFailure,
    this.returnedTaskId,
    this.standardAccount = false,
    this.realTaskStops = false,
  }) : super(
         serverConfig: const ServerConfig(
           id: 'test',
           name: 'Test',
           url: 'https://example.com',
         ),
         workerManager: WorkerManager(),
       );

  final Completer<void>? settingsGate;
  final Completer<void>? sendGate;
  final Object? sendFailure;
  final String? returnedTaskId;

  /// Whether the account is not an administrator: Open WebUI stops a single
  /// task (`POST /api/tasks/stop/{id}`) only for one, and refuses it 401.
  final bool standardAccount;

  /// Whether a task stop goes the service's own route, to [dio]'s adapter.
  final bool realTaskStops;

  /// The tasks the server runs for the account in the chat: one starts as its
  /// completion request is answered, and ends once it is stopped.
  final Set<String> runningTasks = {};

  /// Completes once the server is asked to stop a task it runs, by the task's
  /// id or by the chat's stop, whether it takes that or not.
  final Completer<void> runningTaskStopAsked = Completer<void>();
  final Completer<void> settingsStarted = Completer<void>();
  final Completer<void> sendStarted = Completer<void>();
  int settingsCalls = 0;
  int completionCalls = 0;
  List<Map<String, dynamic>> lastMessages = const [];
  bool? lastEnableImageGeneration;
  String? lastResponseMessageId;
  String? lastConversationId;
  Map<String, dynamic>? lastChatParams;
  String? lastReasoningEffort;
  int broadStopCalls = 0;
  int targetedStopCalls = 0;
  int abortCalls = 0;

  final Map<int, Completer<void>> _settingsCallsReached = {};

  /// Completes once the account's settings have been read [count] times.
  Future<void> settingsCallsReach(int count) => settingsCalls >= count
      ? Future<void>.value()
      : (_settingsCallsReached[count] ??= Completer<void>()).future;

  @override
  Future<Map<String, dynamic>> getUserSettings({Object? authSnapshot}) async {
    settingsCalls += 1;
    _settingsCallsReached.remove(settingsCalls)?.complete();
    if (!settingsStarted.isCompleted) settingsStarted.complete();
    final gate = settingsGate;
    if (gate != null) await gate.future;
    return const <String, dynamic>{};
  }

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async =>
      runningTasks.toList();

  @override
  Future<void> stopTasksByChat(String chatId) async {
    broadStopCalls += 1;
    if (runningTasks.isNotEmpty && !runningTaskStopAsked.isCompleted) {
      runningTaskStopAsked.complete();
    }
    runningTasks.clear();
  }

  @override
  Future<void> stopTaskRaw(String taskId, {ApiAuthSnapshot? authSnapshot}) =>
      realTaskStops
      ? super.stopTaskRaw(taskId, authSnapshot: authSnapshot)
      : stopTask(taskId);

  @override
  Future<void> stopTask(String taskId) async {
    if (realTaskStops) return super.stopTask(taskId);
    targetedStopCalls += 1;
    if (runningTasks.contains(taskId) && !runningTaskStopAsked.isCompleted) {
      runningTaskStopAsked.complete();
    }
    if (standardAccount) {
      final request = RequestOptions(path: '/api/tasks/stop/$taskId');
      throw DioException.badResponse(
        statusCode: 401,
        requestOptions: request,
        response: Response<dynamic>(requestOptions: request, statusCode: 401),
      );
    }
    runningTasks.remove(taskId);
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
    bool viaTether = false,
    String? regenerationMessageId,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    completionCalls += 1;
    lastEnableImageGeneration = enableImageGeneration;
    lastResponseMessageId = responseMessageId;
    lastConversationId = conversationId;
    lastChatParams = chatParams == null
        ? null
        : Map<String, dynamic>.of(chatParams);
    lastReasoningEffort = reasoningEffort;
    lastMessages = messages
        .map((message) => Map<String, dynamic>.from(message))
        .toList(growable: false);
    if (!sendStarted.isCompleted) sendStarted.complete();
    final gate = sendGate;
    if (gate != null) await gate.future;
    final failure = sendFailure;
    if (failure != null) throw failure;

    final taskId = returnedTaskId;
    if (taskId != null) {
      runningTasks.add(taskId);
      return ChatCompletionSession.taskSocket(
        messageId: responseMessageId ?? 'assistant-regen',
        conversationId: conversationId,
        taskId: taskId,
        abort: () async {
          abortCalls += 1;
        },
      );
    }

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

final class _GatedSocketService extends SocketService {
  _GatedSocketService({required this.gate})
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
      );

  final Completer<void> gate;
  final Completer<void> started = Completer<void>();

  @override
  bool get isConnected => false;

  @override
  String? get sessionId => null;

  @override
  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    return false;
  }
}

/// A socket that is down. The send's own reconnect is answered at once; once
/// [holds] says so, a reconnect is answered only when [gate] completes, as the
/// binding of an accepted answer's task to the socket waits for one.
final class _BindingGatedSocketService extends SocketService {
  _BindingGatedSocketService({required this.gate, required this.holds})
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
      );

  final Completer<void> gate;
  final bool Function() holds;
  final Completer<void> bindingStarted = Completer<void>();

  @override
  bool get isConnected => false;

  @override
  String? get sessionId => null;

  @override
  Future<bool> ensureConnected({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (!holds()) return false;
    if (!bindingStarted.isCompleted) bindingStarted.complete();
    await gate.future;
    return false;
  }
}

const _administrator = User(
  id: 'admin',
  username: 'admin',
  email: 'admin@example.test',
  role: 'admin',
);

const _standardAccount = User(
  id: 'member',
  username: 'member',
  email: 'member@example.test',
  role: 'user',
);

/// Answers every request, and records the session each task stop went as.
final class _TaskStopRecorder implements HttpClientAdapter {
  final List<Object?> stoppedAs = <Object?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.startsWith('/api/tasks/stop/')) {
      stoppedAs.add(options.headers['Authorization']);
    }
    return ResponseBody.fromString(
      '{"status": true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
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

/// Completes once [container]'s transcript satisfies [done].
Future<void> _untilMessages(
  ProviderContainer container,
  bool Function(List<ChatMessage> messages) done,
) {
  if (done(container.read(chatMessagesProvider))) return Future.value();
  final reached = Completer<void>();
  final subscription = container.listen<List<ChatMessage>>(
    chatMessagesProvider,
    (_, next) {
      if (done(next) && !reached.isCompleted) reached.complete();
    },
  );
  return reached.future.whenComplete(subscription.close);
}

void main() {
  test('empty historical branch never owns the current state', () {
    check(
      historicalRegenerationStateMatchesForTesting(
        current: const [],
        ownedPostArchivePrefix: const [],
        assistantMessageId: 'missing-assistant',
      ),
    ).isFalse();
  });

  group('historical regeneration state ownership', () {
    final ownedUser = _userMessage(id: 'u1', content: 'Original prompt');
    final ownedTarget = _assistantMessage(
      id: 'a1',
      content: 'Original answer',
    ).copyWith(metadata: const {'archivedVariant': true});

    bool matches(List<ChatMessage> current) =>
        historicalRegenerationStateMatchesForTesting(
          current: current,
          ownedPostArchivePrefix: [ownedUser, ownedTarget],
          assistantMessageId: ownedTarget.id,
        );

    test('accepts only the exact synchronous post-archive state', () {
      check(matches([ownedUser, ownedTarget])).isTrue();
    });

    test('rejects a same-id content mutation in the owned prefix', () {
      check(
        matches([
          ownedUser.copyWith(content: 'Edited concurrently'),
          ownedTarget,
        ]),
      ).isFalse();
      check(
        matches([
          ownedUser,
          ownedTarget.copyWith(content: 'Replaced concurrently'),
        ]),
      ).isFalse();
    });

    test('rejects same-id metadata and status mutations', () {
      check(
        matches([
          ownedUser,
          ownedTarget.copyWith(
            metadata: const {'archivedVariant': true, 'source': 'newer-state'},
          ),
        ]),
      ).isFalse();
      check(
        matches([
          ownedUser,
          ownedTarget.copyWith(
            statusHistory: const [
              ChatStatusUpdate(action: 'newer-update', done: true),
            ],
          ),
        ]),
      ).isFalse();
    });

    test('does not reclaim an appended replacement assistant', () {
      final appended = _assistantMessage(
        id: 'a2',
        content: 'Replacement in progress',
        isStreaming: true,
      );
      check(matches([ownedUser, ownedTarget, appended])).isFalse();
      check(
        matches([
          ownedUser,
          ownedTarget,
          appended.copyWith(id: ownedTarget.id),
        ]),
      ).isFalse();
    });

    test('does not reclaim an in-place version-bearing replay', () {
      final archivedVersion = ChatMessageVersion(
        id: ownedTarget.id,
        content: ownedTarget.content,
        timestamp: ownedTarget.timestamp,
      );
      final replayed = _assistantMessage(
        id: ownedTarget.id,
        content: 'Replacement in progress',
        isStreaming: true,
        versions: [archivedVersion],
      );

      check(matches([ownedUser, replayed])).isFalse();
      check(
        matches([
          ownedUser,
          replayed.copyWith(
            versions: [archivedVersion.copyWith(content: 'Wrong snapshot')],
          ),
        ]),
      ).isFalse();
    });
  });

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
      'rapid replay taps admit only one provider request and one branch',
      () async {
        final settingsGate = Completer<void>();
        final api = _RecordingCompletionApi(settingsGate: settingsGate);
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
          _userMessage(id: 'u2', content: 'Second prompt'),
          _assistantMessage(id: 'a2', content: 'Second answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-single-flight',
            messages: initialMessages,
          ),
          apiService: api,
        );
        addTearDown(container.dispose);

        final first = regenerateHistoricalMessageById(container, 'a1');
        await api.settingsStarted.future.timeout(const Duration(seconds: 1));

        // Preflight has yielded, but no assistant placeholder exists yet and
        // the archived target is deliberately non-streaming. The replay
        // registry, rather than the ordinary streaming guard, rejects this.
        await regenerateHistoricalMessageById(
          container,
          'a1',
        ).timeout(const Duration(seconds: 1));
        check(api.settingsCalls).equals(1);

        settingsGate.complete();
        await first.timeout(const Duration(seconds: 1));
        // JSON completions are intentionally applied in a microtask after the
        // transport has been attached. Wait for that terminal delivery rather
        // than assuming the dispatch future represents stream completion.
        await _untilMessages(
          container,
          (messages) => messages.last.content == 'Regenerated answer',
        );

        check(api.completionCalls).equals(1);
        final messages = container.read(chatMessagesProvider);
        check(messages.where((message) => message.role == 'assistant').length)
            .equals(2);
        check(messages.last.content).equals('Regenerated answer');
      },
    );

    test(
      'A to B to A navigation cannot reacquire replaced preparation state',
      () async {
        final settingsGate = Completer<void>();
        addTearDown(() {
          if (!settingsGate.isCompleted) settingsGate.complete();
        });
        final api = _RecordingCompletionApi(settingsGate: settingsGate);
        final originalA = [
          _userMessage(id: 'u-a', content: 'Prompt A'),
          _assistantMessage(id: 'a-a', content: 'Answer A'),
        ];
        final container = _container(
          initialMessages: originalA,
          activeConversation: _conversation(
            id: 'conversation-a',
            messages: originalA,
          ),
          apiService: api,
        );
        addTearDown(container.dispose);

        final regeneration = regenerateHistoricalMessageById(container, 'a-a');
        await api.settingsStarted.future.timeout(const Duration(seconds: 1));

        final messagesB = [
          _userMessage(id: 'u-b', content: 'Prompt B'),
          _assistantMessage(id: 'a-b', content: 'Answer B'),
        ];
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation(id: 'conversation-b', messages: messagesB));
        container.read(chatMessagesProvider.notifier).setMessages(messagesB);

        // Returning to the same durable id is not enough to recover mutation
        // ownership: navigation may have reloaded a different list snapshot.
        container
            .read(activeConversationProvider.notifier)
            .set(_conversation(id: 'conversation-a', messages: originalA));
        container.read(chatMessagesProvider.notifier).setMessages(originalA);

        final replacementRegeneration = regenerateHistoricalMessageById(
          container,
          'a-a',
        );
        // Direct-route resolution is asynchronous even when no direct binding
        // exists, so admission precedes the observable settings request by a
        // microtask.
        await api.settingsCallsReach(2);
        check(api.settingsCalls).equals(2);

        settingsGate.complete();
        await Future.wait([regeneration, replacementRegeneration])
            .timeout(const Duration(seconds: 1));
        await _untilMessages(
          container,
          (messages) => messages.last.content == 'Regenerated answer',
        );

        // Only the replacement operation can submit. The stale operation was
        // displaced before its await resumed and cannot reacquire A by id.
        check(api.completionCalls).equals(1);
        check(container.read(chatMessagesProvider).last.content)
            .equals('Regenerated answer');
      },
    );

    test(
      'Stop during post-placeholder preflight prevents provider submission',
      () async {
        final socketGate = Completer<void>();
        addTearDown(() {
          if (!socketGate.isCompleted) socketGate.complete();
        });
        final socket = _GatedSocketService(gate: socketGate);
        addTearDown(socket.dispose);
        final api = _RecordingCompletionApi();
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-stop-preflight',
            messages: initialMessages,
          ),
          apiService: api,
          socketService: socket,
        );
        addTearDown(container.dispose);

        final regeneration = regenerateHistoricalMessageById(container, 'a1');
        await socket.started.future.timeout(const Duration(seconds: 1));
        final placeholderBeforeStop = container.read(chatMessagesProvider).last;
        check(placeholderBeforeStop.id).not((it) => it.equals('a1'));
        check(placeholderBeforeStop.isStreaming).isTrue();

        container.read(stopGenerationProvider)();
        final stopped = container.read(chatMessagesProvider).last;
        check(stopped.id).equals(placeholderBeforeStop.id);
        check(stopped.isStreaming).isFalse();
        check(
          stopped.metadata?.containsKey(
                'conduitOpenWebUiRegenerationAttemptId',
              ) ??
              false,
        ).isFalse();

        socketGate.complete();
        await regeneration.timeout(const Duration(seconds: 1));

        check(api.completionCalls).equals(0);
        final after = container.read(chatMessagesProvider).last;
        check(after.id).equals(stopped.id);
        check(after.isStreaming).isFalse();
        check(after.error).isNull();
        check(
          after.metadata?.containsKey(
                'conduitOpenWebUiRegenerationAttemptId',
              ) ??
              false,
        ).isFalse();
      },
    );

    // No one pressed Stop for the task the server started, so it is never
    // stopped through the chat: only an administrator may stop it alone.
    for (final (label, user) in const [
      ('is stopped by its id for an administrator', _administrator),
      ('runs on, unasked, for a standard account', _standardAccount),
    ]) {
      test('Stop while completion POST is pending aborts its returned task, '
          'whose task on the server $label', () async {
        final sendGate = Completer<void>();
        addTearDown(() {
          if (!sendGate.isCompleted) sendGate.complete();
        });
        final administrator = user.role == 'admin';
        final api = _RecordingCompletionApi(
          sendGate: sendGate,
          returnedTaskId: 'task-regeneration',
          standardAccount: !administrator,
        );
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-stop-post',
            messages: initialMessages,
          ),
          apiService: api,
          user: user,
        );
        addTearDown(container.dispose);

        final regeneration = regenerateHistoricalMessageById(container, 'a1');
        await api.sendStarted.future.timeout(const Duration(seconds: 1));
        final placeholderId = container.read(chatMessagesProvider).last.id;

        container.read(stopGenerationProvider)();
        sendGate.complete();
        await regeneration.timeout(const Duration(seconds: 1));
        if (administrator) await api.runningTaskStopAsked.future;

        check(api.completionCalls).equals(1);
        check(api.abortCalls).equals(1);
        check(api.broadStopCalls).equals(1);
        if (administrator) {
          check(api.targetedStopCalls).equals(1);
          check(api.runningTasks).isEmpty();
        } else {
          check(api.targetedStopCalls).equals(0);
          check(api.runningTasks).deepEquals({'task-regeneration'});
        }
        final stopped = container.read(chatMessagesProvider).last;
        check(stopped.id).equals(placeholderId);
        check(stopped.isStreaming).isFalse();
        check(stopped.error).isNull();
        check(
          stopped.metadata?.containsKey(
                'conduitOpenWebUiRegenerationAttemptId',
              ) ??
              false,
        ).isFalse();
      });
    }

    test('an administrator\'s cleanup stop goes as the account that sent the '
        'request, never as one signed in since', () {
      fakeAsync((async) {
        final sendGate = Completer<void>();
        final api = _RecordingCompletionApi(
          sendGate: sendGate,
          returnedTaskId: 'task-regeneration',
          realTaskStops: true,
        )..updateAuthToken('token-admin');
        final server = _TaskStopRecorder();
        api.dio.httpClientAdapter = server;
        // Another account signs in as the stop is on its way, before the
        // session's interceptor reads the token.
        var signedInMeanwhile = false;
        api.dio.interceptors.insert(
          0,
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.startsWith('/api/tasks/stop/')) {
                api.updateAuthToken('token-other');
                signedInMeanwhile = true;
              }
              handler.next(options);
            },
          ),
        );
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-admin-stop',
            messages: initialMessages,
          ),
          apiService: api,
          user: _administrator,
        );
        addTearDown(container.dispose);

        unawaited(
          regenerateHistoricalMessageById(
            container,
            'a1',
          ).catchError((Object _) {}),
        );
        async.flushMicrotasks();
        check(api.sendStarted.isCompleted).isTrue();
        container.read(stopGenerationProvider)();
        sendGate.complete();
        async.elapse(Duration.zero);

        check(signedInMeanwhile).isTrue();
        check(server.stoppedAs).not((it) => it.contains('Bearer token-other'));
      });
    });

    test('a Stop while the answer\'s task waits for the socket is taken, '
        'and stops that task, for a standard account', () async {
      final socketGate = Completer<void>();
      addTearDown(() {
        if (!socketGate.isCompleted) socketGate.complete();
      });
      final api = _RecordingCompletionApi(
        returnedTaskId: 'task-binding',
        standardAccount: true,
      );
      final socket = _BindingGatedSocketService(
        gate: socketGate,
        holds: () => api.runningTasks.isNotEmpty,
      );
      addTearDown(socket.dispose);
      final initialMessages = [
        _userMessage(id: 'u1', content: 'First prompt'),
        _assistantMessage(id: 'a1', content: 'First answer'),
      ];
      final container = _container(
        initialMessages: initialMessages,
        activeConversation: _conversation(
          id: 'conv-binding',
          messages: initialMessages,
        ),
        apiService: api,
        socketService: socket,
        user: _standardAccount,
      );
      addTearDown(container.dispose);

      final regeneration = regenerateHistoricalMessageById(container, 'a1');
      await socket.bindingStarted.future;
      final binding = container.read(chatMessagesProvider).last;
      check(binding.metadata?['taskId']).equals('task-binding');

      final taken = await container.read(stopGenerationSettledProvider)();
      socketGate.complete();
      await regeneration;

      check(taken).isTrue();
      check(api.runningTasks).isEmpty();
      check(api.targetedStopCalls).equals(0);
    });

    test(
      'successful POST cannot attach after a newer assistant becomes tail',
      () async {
        final sendGate = Completer<void>();
        addTearDown(() {
          if (!sendGate.isCompleted) sendGate.complete();
        });
        final api = _RecordingCompletionApi(
          sendGate: sendGate,
          returnedTaskId: 'task-superseded-regeneration',
        );
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-newer-tail-post',
            messages: initialMessages,
          ),
          apiService: api,
          user: _administrator,
        );
        addTearDown(container.dispose);

        final regeneration = regenerateHistoricalMessageById(container, 'a1');
        await api.sendStarted.future.timeout(const Duration(seconds: 1));
        final ownedBefore = container.read(chatMessagesProvider).last;
        final newer = _assistantMessage(
          id: 'newer-assistant',
          content: 'Newer response remains authoritative',
          isStreaming: true,
        ).copyWith(metadata: const <String, dynamic>{'sentinel': 'newer'});
        container.read(chatMessagesProvider.notifier).addMessage(newer);

        sendGate.complete();
        await regeneration.timeout(const Duration(seconds: 1));
        await api.runningTaskStopAsked.future;

        check(api.completionCalls).equals(1);
        check(api.abortCalls).equals(1);
        check(api.targetedStopCalls).equals(1);
        final messages = container.read(chatMessagesProvider);
        final ownedAfter = messages.firstWhere(
          (message) => message.id == ownedBefore.id,
        );
        final expectedOwnedMetadata = Map<String, dynamic>.from(
          ownedBefore.metadata!,
        )..remove('conduitOpenWebUiRegenerationAttemptId');
        check(ownedAfter.metadata)
            .isA<Map<String, dynamic>>()
            .deepEquals(expectedOwnedMetadata);
        check(ownedAfter.copyWith(metadata: ownedBefore.metadata))
            .equals(ownedBefore);
        check(ownedAfter.error).isNull();
        check(messages.last).equals(newer);
        check(messages.last.error).isNull();
        check(messages.last.metadata)
            .isA<Map<String, dynamic>>()
            .deepEquals(const <String, dynamic>{'sentinel': 'newer'});
      },
    );

    test(
      'same-id placeholder replacement revokes replay submission ownership',
      () async {
        final socketGate = Completer<void>();
        addTearDown(() {
          if (!socketGate.isCompleted) socketGate.complete();
        });
        final socket = _GatedSocketService(gate: socketGate);
        addTearDown(socket.dispose);
        final api = _RecordingCompletionApi();
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-replaced-preflight',
            messages: initialMessages,
          ),
          apiService: api,
          socketService: socket,
        );
        addTearDown(container.dispose);

        final regeneration = regenerateHistoricalMessageById(container, 'a1');
        await socket.started.future.timeout(const Duration(seconds: 1));
        final placeholderId = container.read(chatMessagesProvider).last.id;
        final replacement = _assistantMessage(
          id: placeholderId,
          content: 'Independent same-id replacement',
          isStreaming: true,
        );
        container
            .read(chatMessagesProvider.notifier)
            .updateLastMessageWithFunction((_) => replacement);

        socketGate.complete();
        await regeneration.timeout(const Duration(seconds: 1));

        check(api.completionCalls).equals(0);
        final after = container.read(chatMessagesProvider).last;
        check(after).equals(replacement);
      },
    );

    test(
      'in-place OpenWebUI remap retargets a replay still in preflight',
      () async {
        final socketGate = Completer<void>();
        addTearDown(() {
          if (!socketGate.isCompleted) socketGate.complete();
        });
        final socket = _GatedSocketService(gate: socketGate);
        addTearDown(socket.dispose);
        final api = _RecordingCompletionApi();
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'local:conv-remap',
            messages: initialMessages,
          ),
          apiService: api,
          socketService: socket,
        );
        addTearDown(container.dispose);

        final regeneration = regenerateHistoricalMessageById(container, 'a1');
        await socket.started.future.timeout(const Duration(seconds: 1));
        container
            .read(activeConversationProvider.notifier)
            .remapIdInPlace(
              fromId: 'local:conv-remap',
              toId: 'remote-conv-remap',
            );

        socketGate.complete();
        await regeneration.timeout(const Duration(seconds: 1));

        check(api.completionCalls).equals(1);
        check(api.lastConversationId).equals('remote-conv-remap');
        check(container.read(activeConversationProvider)?.id)
            .equals('remote-conv-remap');
      },
    );

    test(
      'a historical replay is sent with the chat\'s saved settings',
      () async {
        final api = _RecordingCompletionApi();
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
          _userMessage(id: 'u2', content: 'Second prompt'),
          _assistantMessage(id: 'a2', content: 'Second answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-historical-params',
            messages: initialMessages,
          ).copyWith(chatParams: const {'system': '', 'seed': 11}),
          apiService: api,
        );
        addTearDown(container.dispose);

        await regenerateHistoricalMessageById(container, 'a1');
        await _untilMessages(
          container,
          (messages) => messages.last.content == 'Regenerated answer',
        );

        check(api.completionCalls).equals(1);
        check(api.lastChatParams)
            .isNotNull()
            .deepEquals(const {'system': '', 'seed': 11});
      },
    );

    test('OpenWebUI post-preseed failure settles its placeholder', () async {
      final api = _RecordingCompletionApi(
        sendFailure: StateError('completion setup failed'),
      );
      final initialMessages = [
        _userMessage(id: 'u1', content: 'First prompt'),
        _assistantMessage(id: 'a1', content: 'First answer'),
      ];
      final container = _container(
        initialMessages: initialMessages,
        activeConversation: _conversation(
          id: 'conv-post-preseed-failure',
          messages: initialMessages,
        ),
        apiService: api,
      );
      addTearDown(container.dispose);

      Object? caught;
      try {
        await regenerateHistoricalMessageById(container, 'a1');
      } catch (error) {
        caught = error;
      }

      check(caught).isNotNull();
      check(api.completionCalls).equals(1);
      final messages = container.read(chatMessagesProvider);
      check(messages.any((message) => message.isStreaming)).isFalse();
      final failed = messages.last;
      check(api.lastResponseMessageId).isNotNull().equals(failed.id);
      check(failed.error).isNotNull();
    });

    test(
      'late OpenWebUI failure settles only its exact non-tail placeholder',
      () async {
        final sendGate = Completer<void>();
        final api = _RecordingCompletionApi(
          sendGate: sendGate,
          sendFailure: StateError('late completion setup failure'),
        );
        final initialMessages = [
          _userMessage(id: 'u1', content: 'First prompt'),
          _assistantMessage(id: 'a1', content: 'First answer'),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-exact-failure-owner',
            messages: initialMessages,
          ),
          apiService: api,
        );
        addTearDown(container.dispose);

        final regeneration = regenerateHistoricalMessageById(container, 'a1');
        await api.sendStarted.future.timeout(const Duration(seconds: 1));
        final ownedAssistantId = api.lastResponseMessageId!;
        final newerAssistant = _assistantMessage(
          id: 'newer-assistant',
          content: 'Newer response',
          isStreaming: true,
        );
        container
            .read(chatMessagesProvider.notifier)
            .addMessage(newerAssistant);

        sendGate.complete();
        Object? caught;
        try {
          await regeneration.timeout(const Duration(seconds: 1));
        } catch (error) {
          caught = error;
        }

        check(caught).isNotNull();
        final messages = container.read(chatMessagesProvider);
        final failed = messages.firstWhere(
          (message) => message.id == ownedAssistantId,
        );
        check(failed.isStreaming).isFalse();
        check(failed.error).isNotNull();
        final newer = messages.firstWhere(
          (message) => message.id == newerAssistant.id,
        );
        check(newer.isStreaming).isTrue();
        check(newer.error).isNull();
      },
    );

    test(
      'forced image replay is request-scoped and preserves a contested toggle',
      () async {
        final sendGate = Completer<void>();
        final api = _RecordingCompletionApi(sendGate: sendGate);
        final initialMessages = [
          _userMessage(id: 'u1', content: 'Draw a cat'),
          _assistantMessage(
            id: 'a1',
            content: '',
            files: const [
              {'type': 'image', 'url': 'https://example.com/cat.png'},
            ],
          ),
        ];
        final container = _container(
          initialMessages: initialMessages,
          activeConversation: _conversation(
            id: 'conv-request-scoped-image',
            messages: initialMessages,
          ),
          apiService: api,
        );
        addTearDown(container.dispose);
        container.read(imageGenerationEnabledProvider.notifier).set(false);

        final regeneration = regenerateHistoricalMessageById(container, 'a1');
        await api.sendStarted.future.timeout(const Duration(seconds: 1));

        check(api.lastEnableImageGeneration).equals(true);
        check(container.read(imageGenerationEnabledProvider)).isFalse();
        // This is a real user preference change while the replay request is
        // in flight. Completion must not restore an older captured value.
        container.read(imageGenerationEnabledProvider.notifier).set(true);

        sendGate.complete();
        await regeneration.timeout(const Duration(seconds: 1));
        check(container.read(imageGenerationEnabledProvider)).isTrue();
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
        await _untilMessages(
          container,
          (messages) => messages.last.content == 'Regenerated answer',
        );

        check(api.completionCalls).equals(1);
        check(api.lastMessages.map((message) => message['role']).toList())
            .deepEquals(['user']);
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
        await _untilMessages(
          container,
          (messages) => messages.last.content == 'Regenerated answer',
        );

        var messages = container.read(chatMessagesProvider);
        final firstReplay = messages.last;
        check(firstReplay.versions.map((version) => version.id).toList())
            .deepEquals(['a1']);

        await regenerateHistoricalMessageById(container, firstReplay.id);
        await _untilMessages(
          container,
          (messages) =>
              messages.last.id != firstReplay.id &&
              messages.last.content == 'Regenerated answer',
        );

        messages = container.read(chatMessagesProvider);
        final secondReplay = messages.last;
        check(secondReplay.content).equals('Regenerated answer');
        check(secondReplay.versions.map((version) => version.id).toList())
            .deepEquals(['a1', firstReplay.id]);
        check(secondReplay.versions.map((version) => version.content).toList())
            .deepEquals(['First answer', 'Regenerated answer']);
      },
    );
  });
}
