import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:dio/dio.dart'
    show
        DioException,
        DioExceptionType,
        Headers,
        HttpClientAdapter,
        RequestOptions,
        Response,
        ResponseBody;
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart' show OutboxKind;
import 'package:conduit_core/models/chat_comparison.dart'
    show
        kMessageServerUnfinishedMetadataKey,
        kMessageUnfinishedAnswersMetadataKey,
        kStoppedHereMetadataKey;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart'
    show findPendingOpenWebUiToolPrompt;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/conversation_parsing.dart'
    show parseFullConversationModel;
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/structured_output.dart'
    show parseOpenWebUIStructuredOutput;
import 'package:conduit_core/services/structured_output_renderer.dart'
    show renderStructuredOutputBlocks;
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/backoff.dart';
import 'package:conduit_core/sync/chat_adapter.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/push_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

const _server = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
);

/// A connected socket that hands each chat's events to that chat's handlers.
class _FakeSocketService extends SocketService {
  _FakeSocketService() : super(serverConfig: _server);

  final _handlers = <SocketChatEventHandler>[];

  @override
  String? get sessionId => 'local-session';

  @override
  bool get isConnected => true;

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
    void wrapped(
      Map<String, dynamic> event,
      void Function(dynamic response)? ack,
    ) {
      final data = event['data'];
      final payload = data is Map ? data['data'] : null;
      final chatId = payload is Map ? payload['chat_id']?.toString() : null;
      if (conversationId != null && chatId != conversationId) return;
      handler(event, ack);
    }

    _handlers.add(wrapped);
    return SocketEventSubscription(
      () => _handlers.removeWhere((candidate) => identical(candidate, wrapped)),
    );
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
    for (final handler in List<SocketChatEventHandler>.of(_handlers)) {
      handler(event, null);
    }
  }
}

/// The server's copy of the chat, and the tasks it reports running for it.
class _FakeApiService extends ApiService {
  _FakeApiService(this.conversation)
    : super(serverConfig: _server, workerManager: WorkerManager());

  Conversation conversation;
  List<String> taskIds = const <String>[];
  int taskLookups = 0;

  @override
  Future<Conversation> getConversation(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    if (readFailures > 0) {
      readFailures--;
      throw StateError('the chat could not be read');
    }
    final held = holdRead;
    if (held != null) await held.future;
    final stored = server?.getChatById(id);
    return stored == null ? conversation : parseFullConversationModel(stored);
  }

  /// Once set, the server's store: the chat it reads, whole or along its
  /// selected branch, and the one its stop finishes.
  FakeOpenWebUiServer? server;

  @override
  Future<Map<String, dynamic>?> getChatRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _send(authSnapshot);
    final stored = server;
    if (stored == null) {
      return <String, dynamic>{
        'id': id,
        'chat': <String, dynamic>{
          'history': <String, dynamic>{'messages': <String, dynamic>{}},
        },
      };
    }
    // Open WebUI answers a chat it does not store, a temporary one among
    // them, as it does one the session may not read: 401.
    return stored.getChatById(id) ??
        (throw DioException(
          requestOptions: RequestOptions(path: '/api/v1/chats/$id'),
          response: Response<Object?>(
            requestOptions: RequestOptions(path: '/api/v1/chats/$id'),
            statusCode: 401,
            data: <String, dynamic>{'detail': 'Not found'},
          ),
          type: DioExceptionType.badResponse,
        ));
  }

  /// The session each read of the chat or its tasks, and each stop, went out
  /// as. One bound to a session replaced since never goes, as the client's
  /// interceptor turns it away.
  final List<String?> sentAs = <String?>[];

  void _send(ApiAuthSnapshot? authSnapshot) {
    if (authSnapshot != null && !authSnapshotIsCurrent(authSnapshot)) {
      throw StateError('the session was replaced');
    }
    sentAs.add(authToken);
  }

  /// Reads of the chat that fail before one answers.
  int readFailures = 0;

  /// While set, a read of the chat waits for it.
  Completer<void>? holdRead;

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) =>
      getChatTaskIdsRaw(chatId);

  @override
  Future<List<String>> getChatTaskIdsRaw(
    String chatId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _send(authSnapshot);
    taskLookups++;
    if (away) throw StateError('the server is away');
    final listed = taskIds;
    afterTaskList?.call();
    return listed;
  }

  /// Runs once the task list is read.
  void Function()? afterTaskList;

  /// While set, the task list cannot be read, as while the server is away.
  bool away = false;

  /// While set, the server answers every stop with an error.
  bool stopsRefused = false;

  /// The chat's stops asked, and the tasks stopped one by one.
  int chatStops = 0;
  final List<String> stoppedTasks = <String>[];

  @override
  Future<void> stopTasksByChat(String chatId) => stopChatTasksRaw(chatId);

  @override
  Future<void> stopChatTasksRaw(
    String chatId, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    _send(authSnapshot);
    chatStops++;
    if (stopsRefused) throw StateError('the stop was refused');
    final hold = holdChatStop;
    if (hold != null) {
      chatStopHeld = true;
      await hold.future;
      // It ends what the account runs in the chat as it reaches the server.
      taskIds = const <String>[];
    }
    server?.stopTasksByChat(chatId);
  }

  /// When set, a chat's stop reaches the server only once this completes;
  /// [chatStopHeld] marks the wait.
  Completer<void>? holdChatStop;
  bool chatStopHeld = false;

  @override
  Future<void> stopTaskRaw(String taskId, {ApiAuthSnapshot? authSnapshot}) =>
      stopTask(taskId);

  @override
  Future<void> stopTask(String taskId) async {
    stoppedTasks.add(taskId);
    if (stopsRefused) throw StateError('the stop was refused');
  }
}

/// Open WebUI's completion route: a request for a chat, recorded in
/// [requested], starts a task there, `task-next`, which [api] lists.
final class _CompletionRoute implements HttpClientAdapter {
  _CompletionRoute(this.api, this.requested);

  final _FakeApiService api;
  final List<String> requested;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final completion =
        options.method == 'POST' && options.path == '/api/chat/completions';
    if (completion) {
      requested.add((options.data as Map)['chat_id'] as String);
      api.taskIds = [...api.taskIds, 'task-next'];
    }
    return ResponseBody.fromString(
      jsonEncode(
        completion
            ? {
                'status': true,
                'task_ids': ['task-next'],
              }
            : const <String, dynamic>{},
      ),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The model list, answered when a test says.
final class _HeldModels extends Models {
  _HeldModels(this._listed);

  final Future<List<Model>> _listed;

  @override
  Future<List<Model>> build() => _listed;
}

/// What a device that offers a model through Tether lists, as Open WebUI
/// 0.13.4 does.
final _deviceModel = Model.fromJson(const <String, dynamic>{
  'id': 'garage-llama',
  'name': 'garage-llama',
  'connection_type': 'local',
  'base_url': 'tether://3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d',
});

/// What 0.13.4's completion router reports for a relay that failed before
/// the device answered.
const _generic = 'Open WebUI: Server Connection Error';

class _SyncClock implements SyncClock {
  @override
  int nowEpochSeconds() => 7000;
}

/// No completion is queued where it is used.
class _NoCompletions implements RequestCompletionRunner {
  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async => throw StateError('no completion was queued');
}

/// Records each drain asked for, by the database it is for.
class _DrainRecordingSyncEngine extends SyncEngine {
  final List<AppDatabase> drained = <AppDatabase>[];

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<void> drainNow() async {}

  @override
  Future<void> drainNowForDatabase(AppDatabase database) async =>
      drained.add(database);
}

ProviderContainer _openChatContainer({
  required _FakeApiService api,
  _FakeSocketService? socket,
  Future<List<Model>>? listed,
  User? user,
  AppDatabase? database,
}) {
  final container = ProviderContainer(
    overrides: [
      if (user != null) currentUserProvider2.overrideWithValue(user),
      secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
      ...openWebUiStorageOpenOverrides(database: database),
      syncEngineProvider.overrideWith(_DrainRecordingSyncEngine.new),
      activeConversationProvider.overrideWith(
        () => _TestActiveConversationNotifier(),
      ),
      socketServiceProvider.overrideWithValue(socket),
      apiServiceProvider.overrideWithValue(api),
      modelsProvider.overrideWith(
        () => _HeldModels(listed ?? Completer<List<Model>>().future),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Conversation _chat(List<ChatMessage> messages) => Conversation(
  id: 'chat-1',
  title: 'Test Chat',
  createdAt: DateTime.utc(2026, 11, 20),
  updatedAt: DateTime.utc(2026, 11, 20),
  messages: messages,
);

ChatMessage _message(String id, String role, String content) => ChatMessage(
  id: id,
  role: role,
  content: content,
  timestamp: DateTime.utc(2026, 11, 20),
);

class _SyncingTestMessagesNotifier extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];

  @override
  void setMessages(List<ChatMessage> messages) {
    state = messages;
  }

  @override
  void updateLastMessageWithFunction(
    ChatMessage Function(ChatMessage) updater,
  ) {
    if (state.isEmpty) return;
    final last = state.last;
    if (last.role != 'assistant') return;
    state = [...state.sublist(0, state.length - 1), updater(last)];
  }

  @override
  void finishStreaming() {
    if (state.isEmpty) return;
    final last = state.last;
    if (last.role != 'assistant' || !last.isStreaming) return;

    final updatedLast = last.copyWith(isStreaming: false);
    state = [...state.sublist(0, state.length - 1), updatedLast];

    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation == null) return;
    ref
        .read(activeConversationProvider.notifier)
        .set(
          activeConversation.copyWith(messages: List<ChatMessage>.from(state)),
        );
  }
}

void main() {
  group('ChatMessagesNotifier error finalization', () {
    test('finishStreaming syncs an early error into activeConversation', () {
      final container = ProviderContainer(
        overrides: [
          chatMessagesProvider.overrideWith(
            () => _SyncingTestMessagesNotifier(),
          ),
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final timestamp = DateTime.now();
      final user = ChatMessage(
        id: 'user-1',
        role: 'user',
        content: 'Hello',
        timestamp: timestamp,
      );
      final assistant = ChatMessage(
        id: 'assistant-1',
        role: 'assistant',
        content: '',
        timestamp: timestamp,
        isStreaming: true,
      );

      container
          .read(activeConversationProvider.notifier)
          .set(
            Conversation(
              id: 'local:test-chat',
              title: 'New Chat',
              createdAt: timestamp,
              updatedAt: timestamp,
              messages: [user, assistant],
            ),
          );

      final notifier = container.read(chatMessagesProvider.notifier);
      notifier.setMessages([user, assistant]);

      notifier.updateLastMessageWithFunction(
        (message) => message.copyWith(
          error: const ChatMessageError(content: 'Transport setup failed'),
        ),
      );
      notifier.finishStreaming();

      final messages = container.read(chatMessagesProvider);
      check(messages).length.equals(2);
      check(messages.last.role).equals('assistant');
      check(messages.last.isStreaming).isFalse();
      check(messages.last.error).isNotNull();
      check(messages.last.error!.content).equals('Transport setup failed');

      final activeConversation = container.read(activeConversationProvider);
      check(activeConversation).isNotNull();
      check(activeConversation!.messages).length.equals(2);
      check(activeConversation.messages.last.isStreaming).isFalse();
      check(activeConversation.messages.last.error).isNotNull();
      check(activeConversation.messages.last.error!.content)
          .equals('Transport setup failed');
    });
  });

  group('a resumed answer that fails before it writes any text', () {
    const failure = ChatMessageError(content: 'The model is not reachable');
    final question = _message('user-1', 'user', 'Hi');
    final answer = _message('assistant-1', 'assistant', '');

    test('settles with its error when the poll sees its task end', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question, answer]))
          ..taskIds = ['task-1'];
        final container = _openChatContainer(api: api);
        check(container.read(chatMessagesProvider)).isEmpty();
        final notifier = container.read(chatMessagesProvider.notifier);
        container
            .read(activeConversationProvider.notifier)
            .set(_chat([question, answer]));
        async.flushMicrotasks();
        check(container.read(chatMessagesProvider).last.isStreaming).isTrue();
        // The poll below is the only one: the monitor's own never fires.
        notifier.debugCancelRemoteTaskMonitorTimer();

        api
          ..taskIds = const <String>[]
          ..conversation = _chat([question, answer.copyWith(error: failure)]);
        check(notifier.debugTaskStatusCheckInFlight).isFalse();
        var polled = false;
        unawaited(
          notifier.debugSyncRemoteTaskStatus().then((_) => polled = true),
        );
        async.flushMicrotasks();
        check(polled).isTrue();

        final settled = container.read(chatMessagesProvider).last;
        check(settled.isStreaming).isFalse();
        check(settled.error?.content).equals(failure.content);
      });
    });

    test('settles with its error when the chat opens after its task ended', () {
      fakeAsync((async) {
        final api = _FakeApiService(
          _chat([question, answer.copyWith(error: failure)]),
        );
        final container = _openChatContainer(api: api);
        check(container.read(chatMessagesProvider)).isEmpty();
        // This device last saw the answer running.
        container
            .read(activeConversationProvider.notifier)
            .set(_chat([question, answer.copyWith(isStreaming: true)]));
        async.flushMicrotasks();

        final settled = container.read(chatMessagesProvider).last;
        check(settled.isStreaming).isFalse();
        check(settled.error?.content).equals(failure.content);
      });
    });
  });

  group('an answer the server stopped in the middle of', () {
    final question = _message('user-1', 'user', 'Why do gales veer?');
    const answerId = 'assistant-1';
    const unfinished = <String, dynamic>{
      kMessageServerUnfinishedMetadataKey: true,
    };
    // A reasoning block as Open WebUI renders one, before any answer text.
    const reasoning =
        '<details type="reasoning" done="true" duration="2">\n'
        '<summary>Thought for 2 seconds</summary>\n'
        '> Fronts turn the wind.\n'
        '</details>';
    // The same block with more of the model's reasoning.
    const moreReasoning =
        '<details type="reasoning" done="true" duration="2">\n'
        '<summary>Thought for 2 seconds</summary>\n'
        '> Fronts turn the wind, and the wind backs behind them.\n'
        '</details>';

    /// The chat open, stored as this device stored it when the answer
    /// started, and the answer streaming here over the socket with
    /// [streamed] so far, its task seen running.
    ({
      ChatMessagesNotifier notifier,
      AppDatabase db,
      ProviderContainer container,
    })
    streamHere(
      FakeAsync async,
      _FakeApiService api,
      String streamed, {
      List<Map<String, dynamic>>? output,
      AppDatabase? database,
      bool withTaskId = true,
      bool listedUnfinished = false,
      User? user,
      String chatId = 'chat-1',
    }) {
      api.taskIds = ['task-1'];
      final container = _openChatContainer(
        api: api,
        database: database,
        user: user,
      );
      final notifier = container.read(chatMessagesProvider.notifier);
      final db = container.read(appDatabaseProvider)!;
      final placeholder = _message(answerId, 'assistant', '').copyWith(
        isStreaming: true,
        output: output,
        metadata: <String, dynamic>{
          'transport': 'taskSocket',
          if (withTaskId) 'taskId': 'task-1',
          'taskConversationId': chatId,
          // As the server's copy lists it once the chat is read again.
          if (listedUnfinished)
            kMessageUnfinishedAnswersMetadataKey: [answerId],
        },
      );
      // A temporary chat is stored nowhere.
      if (!isTemporaryChat(chatId)) {
        unawaited(() async {
          await db.chatsDao.upsertEnvelopeStub(
            id: chatId,
            title: 'Test Chat',
            createdAt: 1,
            updatedAt: 1,
          );
          await db.messagesDao.upsertLocalEchoTurn(
            chatId: chatId,
            user: localEchoRowForMessage(chatId, question),
            // Its output snapshots come later in the stream.
            assistant: localEchoRowForMessage(
              chatId,
              placeholder.copyWith(output: null),
            ),
          );
        }());
      }
      async.flushMicrotasks();
      container
          .read(activeConversationProvider.notifier)
          .set(_chat([question]).copyWith(id: chatId));
      async.flushMicrotasks();
      notifier
        ..addMessage(placeholder)
        ..setSocketSubscriptions(answerId, [() {}]);
      if (streamed.isNotEmpty) notifier.appendToLastMessage(streamed);
      async.elapse(Duration.zero);
      notifier.debugCancelRemoteTaskMonitorTimer();
      return (notifier: notifier, db: db, container: container);
    }

    /// The answer's row as the store keeps it: what the chat opens with.
    Map<String, dynamic> storedAnswer(FakeAsync async, AppDatabase db) {
      MessageRow? row;
      unawaited(
        db.messagesDao.getMessage('chat-1', answerId).then((it) => row = it),
      );
      async.flushMicrotasks();
      return <String, dynamic>{
        ...jsonDecode(row!.payload) as Map<String, dynamic>,
        'content': row!.content,
      };
    }

    /// The answer as the chat opens again from the store: its stored copy,
    /// read by the chat's parser.
    ChatMessage reopened(FakeAsync async, AppDatabase db) {
      final answer = storedAnswer(async, db);
      return parseFullConversationModel(<String, dynamic>{
        'id': 'chat-1',
        'title': 'Test Chat',
        'created_at': 1,
        'updated_at': 1,
        'chat': <String, dynamic>{
          'history': <String, dynamic>{
            'messages': <String, dynamic>{answerId: answer},
            'currentId': answerId,
          },
        },
      }).messages.last;
    }

    /// A Responses reasoning item with [text], as an output snapshot has it.
    Map<String, dynamic> reasoningItem(String text) => <String, dynamic>{
      'type': 'reasoning',
      'summary': [
        <String, dynamic>{'type': 'summary_text', 'text': text},
      ],
    };

    /// Polls the server's task list until the reply settles, past the
    /// socket's own end, which is waited for first.
    void pollTasks(FakeAsync async, ChatMessagesNotifier notifier) {
      for (var poll = 0; poll < 3; poll++) {
        unawaited(notifier.debugSyncRemoteTaskStatus());
        async.flushMicrotasks();
      }
    }

    // Whichever copy holds more is kept, by its text without its reasoning
    // or tool blocks, not by one being the other's beginning. Those blocks
    // count only between copies with as much text, the one with more
    // reasoning first. The error is stored with it, so the chat opens on it,
    // with Retry.
    for (final (label, streamed, onServer, kept)
        in <(String, String, String, String)>[
          (
            'no text, as it saved none before it stopped',
            'Gales veer as the front',
            '',
            'Gales veer as the front',
          ),
          (
            'the same text, with less of the reasoning that streamed here',
            '$moreReasoning\nGales veer',
            '$reasoning\nGales veer',
            '$moreReasoning\nGales veer',
          ),
          (
            'more text, without the reasoning that streamed here',
            '$reasoning\nGales veer',
            'Gales veer as the warm front passes',
            'Gales veer as the warm front passes',
          ),
          (
            'all of its text',
            'Gales veer as the front',
            'Gales veer as the front',
            'Gales veer as the front',
          ),
          ('no text, as this device had none', '', '', ''),
          (
            'less text, written otherwise',
            'Gales veer as the warm front passes',
            'Gales back as',
            'Gales veer as the warm front passes',
          ),
          (
            'more text, written otherwise',
            'Gales veer',
            'Gales back as the warm front passes',
            'Gales back as the warm front passes',
          ),
        ]) {
      test('a cut-off answer whose server copy has $label keeps the longer, '
          'and opens again with the connection lost', () {
        fakeAsync((async) {
          final api = _FakeApiService(_chat([question]));
          final (:notifier, :db, :container) = streamHere(async, api, streamed);
          check(api.taskLookups).equals(1);
          // The server stopped and is back: it runs no task for the chat,
          // and keeps the answer not done, as it was when it stopped.
          api
            ..taskIds = const <String>[]
            ..conversation = _chat([
              question,
              _message(
                answerId,
                'assistant',
                onServer,
              ).copyWith(metadata: unfinished),
            ]);
          pollTasks(async, notifier);

          final answer = container.read(chatMessagesProvider).last;
          check(answer.isStreaming).isFalse();
          check(answer.content).equals(kept);
          final stored = storedAnswer(async, db);
          check(stored)
            ..has((it) => it['content'], 'content').equals(kept)
            ..has((it) => it['done'], 'done').equals(true)
            ..has(
              (it) => (it['error'] as Map?)?['content'],
              'error',
            ).equals(TemporaryChatResume.connectionLostMessage);
        });
      });
    }

    // A copy stored late never cuts a stored answer short: one the store
    // got finished meanwhile stays as it is, with no error, and an unfinished
    // one with more text keeps it, finished with the error.
    for (final finished in [true, false]) {
      test('a cut-off answer stored late keeps the more of a stored answer '
          'that is ${finished ? 'finished' : 'unfinished'}', () {
        fakeAsync((async) {
          final api = _FakeApiService(_chat([question]));
          final (:notifier, :db, container: _) = streamHere(
            async,
            api,
            'Gales veer',
          );
          // A pull stored a fuller answer, before the cut-off copy is.
          unawaited(
            db.messagesDao.upsertLocalEchoTurn(
              chatId: 'chat-1',
              user: localEchoRowForMessage('chat-1', question),
              assistant: localEchoRowForMessage(
                'chat-1',
                _message(
                  answerId,
                  'assistant',
                  'Gales veer as the warm front passes',
                ).copyWith(isStreaming: !finished),
              ),
            ),
          );
          async.flushMicrotasks();
          api
            ..taskIds = const <String>[]
            ..conversation = _chat([
              question,
              _message(
                answerId,
                'assistant',
                'Gales veer',
              ).copyWith(metadata: unfinished),
            ]);
          pollTasks(async, notifier);

          check(storedAnswer(async, db))
            ..has(
              (it) => it['content'],
              'content',
            ).equals('Gales veer as the warm front passes')
            ..has((it) => it['done'], 'done').equals(true)
            ..has((it) => (it['error'] as Map?)?['content'], 'error').equals(
              finished ? null : TemporaryChatResume.connectionLostMessage,
            );
        });
      });
    }

    // A Responses stream sends output snapshots, and text deltas between
    // them that only the text takes: the stored text is read from the
    // output, which must hold all of what was shown.
    for (final ended in ['cut off', 'stopped']) {
      for (final (label, snapshotText, shown) in <(String, String, String)>[
        (
          'streamed past its last output snapshot',
          'Gales veer',
          'Gales veer as the warm front passes',
        ),
        ('differs from its last output snapshot', 'Gales back', 'Gales veer'),
        (
          'streamed past a last output snapshot that ends in a space',
          'Gales veer ',
          'Gales veer as the front',
        ),
        (
          'a last output snapshot runs past',
          'Gales veer as the front',
          'Gales veer',
        ),
      ]) {
        test('an answer $ended after text that $label opens again with that '
            'text', () {
          fakeAsync((async) {
            final api = _FakeApiService(_chat([question]));
            final (:notifier, :db, :container) = streamHere(
              async,
              api,
              shown,
              output: [
                <String, dynamic>{
                  'type': 'message',
                  'role': 'assistant',
                  'content': [
                    <String, dynamic>{
                      'type': 'output_text',
                      'text': snapshotText,
                    },
                  ],
                },
              ],
            );
            api.taskIds = const <String>[];
            if (ended == 'cut off') {
              api.conversation = _chat([
                question,
                _message(
                  answerId,
                  'assistant',
                  '',
                ).copyWith(metadata: unfinished),
              ]);
              pollTasks(async, notifier);
            } else {
              api.conversation = _chat([
                question,
                _message(answerId, 'assistant', ''),
              ]);
              unawaited(container.read(stopGenerationSettledProvider)());
              async.flushMicrotasks();
            }

            check(storedAnswer(async, db))
                .has((it) => it['content'], 'content')
                .equals(shown);
            check(reopened(async, db).content).equals(shown);
          });
        });
      }
    }

    // An image the model made is an output item that renders as markdown:
    // text past it is the only text the output lacks, and opens again as
    // the same markdown, an indented code line's indent included.
    String markdownBlocks(String text) =>
        text.trim().replaceAll(RegExp(r'\n(?:[ \t]*\n)+'), '\n\n');
    for (final ended in ['cut off', 'stopped']) {
      for (final (label, past) in <(String, String)>[
        ('text', 'The vane turns with the gale.'),
        ('indented code', '\n\n    vane.turn(gale)'),
      ]) {
        test('an answer $ended after $label that streamed past a generated '
            'image opens again with the image once and the $label shown', () {
          fakeAsync((async) {
            final snapshot = [
              <String, dynamic>{
                'type': 'image_generation_call',
                'result': 'data:image/png;base64,iVBORw0KGgo=',
                'revised_prompt': 'A weather vane',
              },
            ];
            final api = _FakeApiService(_chat([question]));
            final shown =
                '${renderStructuredOutputBlocks(parseOpenWebUIStructuredOutput(snapshot))}'
                '$past';
            final (:notifier, :db, :container) = streamHere(
              async,
              api,
              shown,
              output: snapshot,
            );
            api.taskIds = const <String>[];
            if (ended == 'cut off') {
              api.conversation = _chat([
                question,
                _message(
                  answerId,
                  'assistant',
                  '',
                ).copyWith(metadata: unfinished),
              ]);
              pollTasks(async, notifier);
            } else {
              api.conversation = _chat([
                question,
                _message(answerId, 'assistant', ''),
              ]);
              unawaited(container.read(stopGenerationSettledProvider)());
              async.flushMicrotasks();
            }

            final opened = reopened(async, db).content;
            check('![A weather vane]'.allMatches(opened).length).equals(1);
            check(markdownBlocks(opened)).equals(markdownBlocks(shown));
          });
        });
      }
    }

    // Reasoning deltas reach the shown reasoning too, and not the output's
    // reasoning item: what opens again is all the reasoning shown, prose or
    // none. An output in step with the text shown is stored as it is.
    for (final ended in ['cut off', 'stopped']) {
      for (final (label, snapshot, streamed, opensWith, outputKept)
          in <(String, List<Map<String, dynamic>>, String, String, bool)>[
            (
              'reasoning past its last output snapshot',
              [reasoningItem('Fronts turn the wind.')],
              moreReasoning,
              'and the wind backs behind them',
              false,
            ),
            (
              'reasoning past its last output snapshot, then text',
              [
                reasoningItem('Fronts turn the wind.'),
                <String, dynamic>{
                  'type': 'message',
                  'content': [
                    <String, dynamic>{
                      'type': 'output_text',
                      'text': 'Gales veer',
                    },
                  ],
                },
              ],
              '$moreReasoning\nGales veer',
              'and the wind backs behind them',
              false,
            ),
            (
              'reasoning and text in step with its output',
              [
                reasoningItem(
                  'Fronts turn the wind, and the wind backs behind them.',
                ),
                <String, dynamic>{
                  'type': 'message',
                  'content': [
                    <String, dynamic>{
                      'type': 'output_text',
                      'text': 'Gales veer',
                    },
                  ],
                },
              ],
              '',
              'and the wind backs behind them',
              true,
            ),
          ]) {
        test('an answer $ended after $label opens again with all the '
            'reasoning shown', () {
          fakeAsync((async) {
            final api = _FakeApiService(_chat([question]));
            final shown = streamed.isEmpty
                ? renderStructuredOutputBlocks(
                    parseOpenWebUIStructuredOutput(snapshot),
                  )
                : streamed;
            final (:notifier, :db, :container) = streamHere(
              async,
              api,
              shown,
              output: snapshot,
            );
            api.taskIds = const <String>[];
            if (ended == 'cut off') {
              api.conversation = _chat([
                question,
                _message(
                  answerId,
                  'assistant',
                  '',
                ).copyWith(metadata: unfinished),
              ]);
              pollTasks(async, notifier);
            } else {
              api.conversation = _chat([
                question,
                _message(answerId, 'assistant', ''),
              ]);
              unawaited(container.read(stopGenerationSettledProvider)());
              async.flushMicrotasks();
            }

            check(reopened(async, db).content).contains(opensWith);
            check(storedAnswer(async, db)['output'])
                .has((it) => it != null, 'output kept')
                .equals(outputKept);
          });
        });
      }
    }

    test('a cut-off answer stored over an unfinished answer with more '
        'reasoning in its output keeps that reasoning', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (:notifier, :db, container: _) = streamHere(
          async,
          api,
          reasoning,
        );
        // A pull stored the server's checkpoint, its reasoning in its
        // output, further on than what streamed here.
        unawaited(
          db.messagesDao.upsertLocalEchoTurn(
            chatId: 'chat-1',
            user: localEchoRowForMessage('chat-1', question),
            assistant: localEchoRowForMessage(
              'chat-1',
              _message(answerId, 'assistant', '').copyWith(
                isStreaming: true,
                output: [
                  reasoningItem(
                    'Fronts turn the wind, and the wind backs behind them.',
                  ),
                ],
              ),
            ),
          ),
        );
        async.flushMicrotasks();
        api
          ..taskIds = const <String>[]
          ..conversation = _chat([
            question,
            _message(answerId, 'assistant', '').copyWith(metadata: unfinished),
          ]);
        pollTasks(async, notifier);

        check(reopened(async, db).content)
            .contains('and the wind backs behind them');
      });
    });

    test('a cut-off answer keeps the text that streamed here together with '
        'its own output, not the server\'s older one', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (:notifier, :db, :container) = streamHere(
          async,
          api,
          'Gales veer as the warm front passes',
        );
        api
          ..taskIds = const <String>[]
          ..conversation = _chat([
            question,
            _message(answerId, 'assistant', 'Gales veer').copyWith(
              metadata: unfinished,
              output: const [
                <String, dynamic>{
                  'type': 'message',
                  'content': [
                    <String, dynamic>{
                      'type': 'output_text',
                      'text': 'Gales veer',
                    },
                  ],
                },
              ],
            ),
          ]);
        pollTasks(async, notifier);

        final stored = storedAnswer(async, db);
        check(stored)
          ..has(
            (it) => it['content'],
            'content',
          ).equals('Gales veer as the warm front passes')
          ..has((it) => it['output'], 'output').isNull();
      });
    });

    // A read of the server's copy that fails is tried again on the task
    // checks' schedule, as for an answer restored running.
    for (final readFailsOnce in [false, true]) {
      test(
        'a chat opened again on an answer the server stopped in the middle '
        'of, not shown running, settles with the fuller copy and the '
        'connection lost${readFailsOnce ? ', its first read failing' : ''}',
        () {
          fakeAsync((async) {
            // This device stored an earlier copy of the answer; the server's,
            // not done, has more, and no task runs for it.
            final stale = _message(
              answerId,
              'assistant',
              'Gales veer',
            ).copyWith(metadata: unfinished);
            final api = _FakeApiService(
              _chat([
                question,
                _message(
                  answerId,
                  'assistant',
                  'Gales veer as the front',
                ).copyWith(metadata: unfinished),
              ]),
            )..readFailures = readFailsOnce ? 1 : 0;
            final container = _openChatContainer(api: api);
            final db = container.read(appDatabaseProvider)!;
            unawaited(() async {
              await db.chatsDao.upsertEnvelopeStub(
                id: 'chat-1',
                title: 'Test Chat',
                createdAt: 1,
                updatedAt: 1,
              );
              await db.messagesDao.upsertLocalEchoTurn(
                chatId: 'chat-1',
                user: localEchoRowForMessage('chat-1', question),
                assistant: localEchoRowForMessage(
                  'chat-1',
                  stale.copyWith(isStreaming: true),
                ),
              );
            }());
            async.flushMicrotasks();
            container.read(chatMessagesProvider);
            container
                .read(activeConversationProvider.notifier)
                .set(_chat([question, stale]));
            async.flushMicrotasks();
            if (readFailsOnce) {
              final notifier = container.read(chatMessagesProvider.notifier)
                ..debugCancelRemoteTaskMonitorTimer();
              pollTasks(async, notifier);
            }

            final answer = container.read(chatMessagesProvider).last;
            check(answer.content).equals('Gales veer as the front');
            check(answer.error?.content)
                .equals(TemporaryChatResume.connectionLostMessage);
            check(storedAnswer(async, db))
              ..has(
                (it) => it['content'],
                'content',
              ).equals('Gales veer as the front')
              ..has((it) => it['done'], 'done').equals(true)
              ..has(
                (it) => (it['error'] as Map?)?['content'],
                'error',
              ).equals(TemporaryChatResume.connectionLostMessage);
          });
        },
      );
    }

    // In a chat another person owns, an answer that names no author is
    // theirs, and runs under a task this account's list never shows.
    for (final openedRunning in [false, true]) {
      test(
        'a chat of another person\'s opened again on an answer of theirs the '
        'server keeps not done${openedRunning ? ', restored running,' : ''} '
        'is not settled as cut off when this account runs no task',
        () {
          fakeAsync((async) {
            final opened = _message(
              answerId,
              'assistant',
              'Gales veer',
            ).copyWith(metadata: unfinished, isStreaming: openedRunning);
            final api = _FakeApiService(
              _chat([
                question,
                _message(
                  answerId,
                  'assistant',
                  'Gales veer as the front',
                ).copyWith(metadata: unfinished),
              ]),
            );
            final container = _openChatContainer(
              api: api,
              user: const User(
                id: 'user-a',
                username: 'avery',
                email: 'avery@example.test',
                role: 'user',
              ),
            );
            final db = container.read(appDatabaseProvider)!;
            unawaited(() async {
              await db.chatsDao.upsertEnvelopeStub(
                id: 'chat-1',
                title: 'Test Chat',
                createdAt: 1,
                updatedAt: 1,
              );
              await db.messagesDao.upsertLocalEchoTurn(
                chatId: 'chat-1',
                user: localEchoRowForMessage('chat-1', question),
                assistant: localEchoRowForMessage('chat-1', opened),
              );
            }());
            async.flushMicrotasks();
            container.read(chatMessagesProvider);
            container
                .read(activeConversationProvider.notifier)
                .set(_chat([question, opened]).copyWith(userId: 'user-b'));
            async.flushMicrotasks();
            check(api.taskLookups).equals(1);

            check(container.read(chatMessagesProvider).last.error).isNull();
            check(storedAnswer(async, db))
                .has((it) => it['error'], 'error')
                .isNull();
          });
        },
      );
    }

    test('an answer waiting for a saved tool approval, with no task, keeps '
        'its prompt and is not failed', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (:notifier, db: _, :container) = streamHere(
          async,
          api,
          'Checking the barometer',
        );
        api
          ..taskIds = const <String>[]
          ..conversation = _chat([
            question,
            _message(answerId, 'assistant', 'Checking the barometer').copyWith(
              metadata: unfinished,
              output: const [
                <String, dynamic>{
                  'type': 'function_call',
                  'call_id': 'call-1',
                  'name': 'read_barometer',
                  'arguments': '{}',
                  'status': 'requires_approval',
                },
              ],
            ),
          ]);
        pollTasks(async, notifier);

        final messages = container.read(chatMessagesProvider);
        check(messages.last.error).isNull();
        check(findPendingOpenWebUiToolPrompt(messages)).isNotNull();
      });
    });

    // Open WebUI's stop of a chat with no task running finishes each of its
    // answers with the text it had stored, often none.
    for (final (label, streamed, onServer, kept)
        in <(String, String, ChatMessage, String)>[
          (
            'only reasoning',
            reasoning,
            _message(answerId, 'assistant', ''),
            reasoning,
          ),
          (
            'the same text as the server\'s unfinished copy',
            'Gales veer',
            _message(
              answerId,
              'assistant',
              'Gales veer',
            ).copyWith(metadata: unfinished),
            'Gales veer',
          ),
          (
            'nothing, and the server\'s copy is unfinished',
            '',
            _message(answerId, 'assistant', '').copyWith(metadata: unfinished),
            '',
          ),
        ]) {
      test('a Stop with no task running on an answer that streamed $label '
          'stores it finished, as the chat opens again', () {
        fakeAsync((async) {
          final api = _FakeApiService(_chat([question]));
          final (notifier: _, :db, :container) = streamHere(
            async,
            api,
            streamed,
          );
          api
            ..taskIds = const <String>[]
            ..conversation = _chat([question, onServer]);
          var settled = false;
          unawaited(
            container
                .read(stopGenerationSettledProvider)()
                .then((_) => settled = true),
          );
          async.flushMicrotasks();
          check(settled).isTrue();

          check(storedAnswer(async, db))
            ..has((it) => it['content'], 'content').equals(kept)
            ..has((it) => it['done'], 'done').equals(true);
        });
      });
    }

    test('a Stop with no task that the server does not take keeps what '
        'streamed on this device until a later ask is taken, then sends '
        'it', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (notifier: _, :db, :container) = streamHere(
          async,
          api,
          'Gales veer',
        );
        api
          ..taskIds = const <String>[]
          ..stopsRefused = true
          ..conversation = _chat([
            question,
            _message(answerId, 'assistant', ''),
          ]);
        bool updateQueued() {
          var queued = false;
          unawaited(
            db.outboxDao
                .activeForChat('chat-1')
                .then(
                  (ops) => queued = ops.any(
                    (op) => op.kind == OutboxKind.updateChat.name,
                  ),
                ),
          );
          async.flushMicrotasks();
          return queued;
        }

        unawaited(container.read(stopGenerationSettledProvider)());
        async.flushMicrotasks();
        check(storedAnswer(async, db))
          ..has((it) => it['content'], 'content').equals('Gales veer')
          ..has(
            (it) => (it['metadata'] as Map?)?[kStoppedHereMetadataKey],
            'stopped here',
          ).equals(true);
        // The stop is owed in the store: the chat's queued update asks for it
        // again, and carries the answer as the server holds it until a stop
        // is taken.
        check(updateQueued()).isTrue();

        api.stopsRefused = false;
        unawaited(container.read(stopOpenWebUiMainResponseProvider)());
        async.flushMicrotasks();
        check(storedAnswer(async, db))
          ..has((it) => it['content'], 'content').equals('Gales veer')
          ..has(
            (it) => (it['metadata'] as Map?)?[kStoppedHereMetadataKey],
            'stopped here',
          ).isNull();
        check(updateQueued()).isTrue();
      });
    });

    test('a Stop with no task that the server does not take, then takes on a '
        'later ask while its copy is read, sends what streamed', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (notifier: _, :db, :container) = streamHere(
          async,
          api,
          'Gales veer',
        );
        final read = Completer<void>();
        api
          ..taskIds = const <String>[]
          ..stopsRefused = true
          ..holdRead = read
          ..conversation = _chat([
            question,
            _message(answerId, 'assistant', ''),
          ]);
        unawaited(container.read(stopGenerationSettledProvider)());
        async.flushMicrotasks();

        // The next ask is accepted while the server's copy is still read.
        api.stopsRefused = false;
        unawaited(container.read(stopOpenWebUiMainResponseProvider)());
        async.flushMicrotasks();
        api.holdRead = null;
        read.complete();
        async.flushMicrotasks();

        var sent = false;
        unawaited(
          db.outboxDao
              .activeForChat('chat-1')
              .then(
                (ops) => sent = ops.any(
                  (op) => op.kind == OutboxKind.updateChat.name,
                ),
              ),
        );
        async.flushMicrotasks();
        check(sent).isTrue();
        check(storedAnswer(async, db))
          ..has((it) => it['content'], 'content').equals('Gales veer')
          ..has(
            (it) => (it['metadata'] as Map?)?[kStoppedHereMetadataKey],
            'stopped here',
          ).isNull();
      });
    });

    test('a cut-off answer, once stored, asks for a drain of its store, so '
        'its update goes out with no next send and no relaunch', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (:notifier, :db, :container) = streamHere(
          async,
          api,
          'Gales veer as the front',
        );
        final engine = container.read(
          syncEngineProvider.notifier,
        ) as _DrainRecordingSyncEngine;
        api
          ..taskIds = const <String>[]
          ..conversation = _chat([
            question,
            _message(answerId, 'assistant', '').copyWith(metadata: unfinished),
          ]);
        pollTasks(async, notifier);

        check(storedAnswer(async, db))
          ..has(
            (it) => it['content'],
            'content',
          ).equals('Gales veer as the front')
          ..has((it) => it['done'], 'done').equals(true);
        check(engine.drained).isNotEmpty();
        check(engine.drained.every((it) => identical(it, db))).isTrue();
      });
    });

    /// The chat on the server, which [database] stores this device's side
    /// of: the question and its answer not done and empty, as Open WebUI
    /// stores a turn before its task starts, and holds it once its server
    /// stopped in the middle of it. `pull` reads the chat's body, as a sync
    /// does; `drain` sends what the outbox holds, as a reconnect or a launch
    /// does, through a drainer that knows only the store.
    ({FakeOpenWebUiServer server, void Function() pull, void Function() drain})
    serverOf(FakeAsync async, AppDatabase database) {
      final server = FakeOpenWebUiServer(nowEpochSeconds: () => 7000)
        ..seedChat(
          id: 'chat-1',
          blob: <String, dynamic>{
            'title': 'Test Chat',
            'history': <String, dynamic>{
              'messages': <String, dynamic>{
                question.id: <String, dynamic>{
                  'id': question.id,
                  'parentId': null,
                  'childrenIds': [answerId],
                  'role': 'user',
                  'content': question.content,
                },
                answerId: <String, dynamic>{
                  'id': answerId,
                  'parentId': question.id,
                  'childrenIds': <String>[],
                  'role': 'assistant',
                  'content': '',
                  'done': false,
                },
              },
              'currentId': answerId,
            },
          },
          createdAt: 1,
          updatedAt: 1,
        );
      final client = FakeSyncApiClient(server);
      final locks = ConversationLocks();
      final remapper = IdRemapper(database);
      addTearDown(remapper.dispose);
      final pullSync = PullSync(
        client: client,
        db: database,
        locks: locks,
        remapper: remapper,
      );
      final clock = _SyncClock();
      final drainer = OutboxDrainer(
        db: database,
        clock: clock,
        backoff: Backoff(jitter: () => 0.0),
        isOnline: () => true,
        completion: _NoCompletions(),
        adapters: [
          ChatAdapter(
            pull: pullSync,
            push: PushSync(
              client: client,
              db: database,
              chatLocks: locks,
              folderLocks: FolderLocks(),
              clock: clock,
              remapper: remapper,
            ),
          ),
        ],
      );
      return (
        server: server,
        pull: () {
          unawaited(pullSync.pullChat('chat-1'));
          async.elapse(Duration.zero);
        },
        drain: () {
          var drained = false;
          unawaited(drainer.drain().then((_) => drained = true));
          async.elapse(const Duration(seconds: 1));
          check(drained).isTrue();
        },
      );
    }

    Map<String, dynamic> answerOn(FakeOpenWebUiServer server) =>
        ((server.getChatById('chat-1')!['chat'] as Map)['history']
                as Map)['messages'][answerId]
            as Map<String, dynamic>;

    // The server is stopped while the answer streams, Stop is pressed, and
    // the server is started again with no task running and its copy of the
    // answer not done and empty. What streamed here reaches it, as the outbox
    // drains once the connection is back, or at the next launch.
    for (final relaunched in [false, true]) {
      test('a Stop while the server is away reaches it once it is back'
          '${relaunched ? ', after a relaunch' : ''}: the queued update stops '
          'the chat and sends what streamed', () {
        fakeAsync((async) {
          final database = AppDatabase(NativeDatabase.memory());
          addTearDown(database.close);
          final (:server, :pull, :drain) = serverOf(async, database);

          final api = _FakeApiService(_chat([question]));
          final (notifier: _, :db, :container) = streamHere(
            async,
            api,
            'Gales veer',
            database: database,
          );
          api
            ..away = true
            ..readFailures = 1
            ..stopsRefused = true;
          unawaited(container.read(stopGenerationSettledProvider)());
          async.flushMicrotasks();

          check(storedAnswer(async, db))
            ..has((it) => it['content'], 'content').equals('Gales veer')
            ..has(
              (it) => (it['metadata'] as Map?)?[kStoppedHereMetadataKey],
              'stopped here',
            ).equals(true);
          List<OutboxOp>? queued;
          unawaited(
            db.outboxDao.activeForChat('chat-1').then((ops) => queued = ops),
          );
          async.flushMicrotasks();
          check(queued!.map((op) => op.kind))
              .contains(OutboxKind.updateChat.name);

          if (relaunched) container.dispose();

          // The server is back, with no task running; it holds the answer as
          // it stopped it. The chat's body is read, as a sync does, and keeps
          // what was stopped here; then the outbox drains.
          pull();
          check(storedAnswer(async, db))
            ..has((it) => it['content'], 'content').equals('Gales veer')
            ..has(
              (it) => (it['metadata'] as Map?)?[kStoppedHereMetadataKey],
              'stopped here',
            ).equals(true);
          drain();

          check(answerOn(server))
            ..has((it) => it['done'], 'done').equals(true)
            ..has((it) => it['content'], 'content').equals('Gales veer');
          check(server.chatStops).deepEquals(['chat-1']);
          check(storedAnswer(async, db))
            ..has((it) => it['content'], 'content').equals('Gales veer')
            ..has(
              (it) => (it['metadata'] as Map?)?[kStoppedHereMetadataKey],
              'stopped here',
            ).isNull();
        });
      });
    }

    // The answer's own stop asks its chat's stop, and so does the Stop's
    // stop of the chat: one request does both.
    test('a Stop with the server up asks the chat\'s stop once', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (notifier: _, db: _, :container) = streamHere(
          async,
          api,
          'Gales veer',
        );

        bool? taken;
        unawaited(
          container
              .read(stopGenerationSettledProvider)()
              .then((it) => taken = it),
        );
        async.flushMicrotasks();

        check(taken).equals(true);
        check(api.chatStops).equals(1);
        check(api.stoppedTasks).isEmpty();
      });
    });

    // Two devices of the account settle the same cut-off answer: this one
    // from the server's empty copy, or with less of it, while the other's
    // push lands with the text it kept. This one's push comes after, and the
    // server, holding the answer finished, would take it.
    for (final streamed in ['', 'Gales veer']) {
      test('a cut-off answer settled here with '
          '${streamed.isEmpty ? 'no text' : 'less text'} leaves the fuller '
          'text another device sent the server in place, and takes it', () {
        fakeAsync((async) {
          const fuller = 'Gales veer as the warm front passes';
          final database = AppDatabase(NativeDatabase.memory());
          addTearDown(database.close);
          final (:server, :pull, :drain) = serverOf(async, database);
          final api = _FakeApiService(_chat([question]));
          final (:notifier, :db, container: _) = streamHere(
            async,
            api,
            streamed,
            database: database,
          );
          api
            ..taskIds = const <String>[]
            ..conversation = _chat([
              question,
              _message(
                answerId,
                'assistant',
                '',
              ).copyWith(metadata: unfinished),
            ]);
          pollTasks(async, notifier);
          check(storedAnswer(async, db))
            ..has((it) => it['done'], 'done').equals(true)
            ..has((it) => it['content'], 'content').equals(streamed);

          // The other device's push lands, after its stop of the chat.
          server.stopTasksByChat('chat-1');
          final chat =
              server.getChatById('chat-1')!['chat'] as Map<String, dynamic>;
          ((chat['history'] as Map)['messages'] as Map)[answerId] = {
            ...answerOn(server),
            'content': fuller,
            'done': true,
            'error': {'content': TemporaryChatResume.connectionLostMessage},
          };
          server.updateChat('chat-1', chat);

          pull();
          drain();

          check(answerOn(server))
            ..has((it) => it['done'], 'done').equals(true)
            ..has((it) => it['content'], 'content').equals(fuller);
          check(storedAnswer(async, db))
              .has((it) => it['content'], 'content')
              .equals(fuller);
        });
      });
    }

    // A Stop the server did not take is asked again as the next turn is
    // admitted. The chat's stop ends every task the account runs there, and
    // with none running it finishes the account's answers that are not done,
    // on every branch, rejecting a tool call one waits on. Only an
    // administrator may stop a single task.
    ({
      String label,
      List<String> running,
      bool withTaskId,
      bool listedUnfinished,
      ({bool shown, String? author})? waiting,
      bool admits,
      int chatStops,
    })
    reAsk(
      String label, {
      List<String> running = const <String>[],
      bool withTaskId = true,
      bool listedUnfinished = false,
      ({bool shown, String? author})? waiting,
      bool admits = false,
      int chatStops = 0,
    }) => (
      label: label,
      running: running,
      withTaskId: withTaskId,
      listedUnfinished: listedUnfinished,
      waiting: waiting,
      admits: admits,
      chatStops: chatStops,
    );

    for (final (
          :label,
          :running,
          :withTaskId,
          :listedUnfinished,
          :waiting,
          :admits,
          :chatStops,
        )
        in [
          reAsk(
            'another device answers in the chat, stops nothing',
            running: ['task-elsewhere'],
            admits: true,
          ),
          reAsk(
            'its own task still runs, stops the chat, which runs only that',
            running: ['task-1'],
            admits: true,
            chatStops: 1,
          ),
          reAsk(
            'its own task still runs, the answer listed unfinished under its '
            'own id, stops the chat',
            running: ['task-1'],
            listedUnfinished: true,
            admits: true,
            chatStops: 1,
          ),
          reAsk(
            'its own task and another device\'s run, stays owed',
            running: ['task-1', 'task-elsewhere'],
          ),
          reAsk(
            'nothing runs but an answer waits for a tool\'s approval, stays '
            'owed',
            waiting: (shown: true, author: null),
          ),
          reAsk(
            'nothing runs but an answer the account paused on another device '
            'waits for a tool\'s approval on a branch not shown, stays owed',
            waiting: (shown: false, author: FakeOpenWebUiServer.userId),
          ),
          reAsk(
            'nothing runs but an answer that names its author as empty, the '
            'chat owner\'s, waits for a tool\'s approval, stays owed',
            waiting: (shown: false, author: ''),
          ),
          reAsk(
            'nothing runs but another person\'s answer waits for a tool\'s '
            'approval, stops the chat, which leaves theirs',
            waiting: (shown: false, author: 'user-b'),
            admits: true,
            chatStops: 1,
          ),
          reAsk(
            'a task runs that cannot be told to be its own, stays owed',
            running: ['task-elsewhere'],
            withTaskId: false,
          ),
        ]) {
      test('a Stop asked again as a next turn is admitted, while $label', () {
        fakeAsync((async) {
          final api = _FakeApiService(_chat([question]));
          final (notifier: _, :db, :container) = streamHere(
            async,
            api,
            'Gales veer',
            withTaskId: withTaskId,
            listedUnfinished: listedUnfinished,
            user: const User(
              id: FakeOpenWebUiServer.userId,
              username: 'avery',
              email: 'avery@example.test',
              role: 'user',
            ),
          );
          api
            ..away = true
            ..readFailures = 1
            ..stopsRefused = true;
          unawaited(container.read(stopGenerationSettledProvider)());
          async.flushMicrotasks();
          final chatStopsBefore = api.chatStops;

          // The server is back. The stopped answer finished there, and an
          // answer beside it may wait for a tool's approval.
          const waitingId = 'assistant-2';
          final server = FakeOpenWebUiServer(nowEpochSeconds: () => 7000)
            ..seedChat(
              id: 'chat-1',
              createdAt: 1,
              updatedAt: 1,
              blob: <String, dynamic>{
                'title': 'Test Chat',
                'history': <String, dynamic>{
                  'messages': <String, dynamic>{
                    question.id: <String, dynamic>{
                      'id': question.id,
                      'parentId': null,
                      'childrenIds': [answerId, if (waiting != null) waitingId],
                      'role': 'user',
                      'content': question.content,
                    },
                    answerId: <String, dynamic>{
                      'id': answerId,
                      'parentId': question.id,
                      'childrenIds': <String>[],
                      'role': 'assistant',
                      'content': 'Gales veer',
                      'done': true,
                    },
                    if (waiting != null)
                      waitingId: <String, dynamic>{
                        'id': waitingId,
                        'parentId': question.id,
                        'childrenIds': <String>[],
                        'role': 'assistant',
                        'content': '',
                        'done': false,
                        'user_id': ?waiting.author,
                        'output': [
                          <String, dynamic>{
                            'type': 'function_call',
                            'call_id': 'call-1',
                            'name': 'trail_weather',
                            'arguments': '{}',
                            'status': 'requires_approval',
                          },
                        ],
                      },
                  },
                  'currentId': waiting?.shown ?? false ? waitingId : answerId,
                },
              },
            );
          for (final task in running) {
            server.runTask('chat-1', task);
          }
          api
            ..away = false
            ..stopsRefused = false
            ..taskIds = running
            ..server = server;
          bool? admitted;
          unawaited(
            container
                .read(chatMessagesProvider.notifier)
                .settlePendingCancellation(
                  chatId: 'chat-1',
                  database: db,
                  api: api,
                  authSessionEpoch: container.read(
                    openWebUiAuthSessionEpochProvider,
                  ),
                )!
                .then((ok) => admitted = ok),
          );
          async.flushMicrotasks();

          check(admitted).equals(admits);
          check(api.chatStops - chatStopsBefore).equals(chatStops);
          check(api.stoppedTasks).isEmpty();
          if (waiting != null) {
            final stored =
                ((server.getChatById('chat-1')!['chat'] as Map)['history']
                        as Map)['messages'][waitingId]
                    as Map;
            check(stored['done']).equals(false);
            check((stored['output'] as List).single['status'])
                .equals('requires_approval');
          }
        });
      });
    }

    // A pressed Stop's stop of the chat ends every task the account runs
    // there, one a request sent before it is answered would start.
    test('a request to the chat while a pressed Stop\'s stop of it is on its '
        'way waits until that stop is answered, and its own task runs on', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (notifier: _, db: _, :container) = streamHere(
          async,
          api,
          'Gales veer',
        );
        final stop = Completer<void>();
        final requested = <String>[];
        api
          ..holdChatStop = stop
          ..dio.interceptors.clear()
          ..dio.httpClientAdapter = _CompletionRoute(api, requested);
        unawaited(container.read(stopGenerationSettledProvider)());
        async.flushMicrotasks();
        check(api.chatStopHeld).isTrue();

        unawaited(
          api.sendMessageSession(
            messages: const [
              {'role': 'user', 'content': 'And the squall?'},
            ],
            model: 'gale-model',
            conversationId: 'chat-1',
            responseMessageId: 'assistant-next',
          ),
        );
        async.elapse(Duration.zero);
        check(requested).isEmpty();
        stop.complete();
        async.elapse(Duration.zero);

        check(requested).deepEquals(['chat-1']);
        check(api.taskIds).deepEquals(['task-next']);
      });
    });

    // The chat's stop ends every task the account runs there, one a request
    // sent between the task read and the stop would start among them.
    test('a request to the chat while a Stop is asked again waits until that '
        'stop is answered, and its own task runs on', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (notifier: _, :db, :container) = streamHere(
          async,
          api,
          'Gales veer',
        );
        api
          ..away = true
          ..readFailures = 1
          ..stopsRefused = true;
        unawaited(container.read(stopGenerationSettledProvider)());
        async.flushMicrotasks();

        // The server is back with nothing running; the Stop is asked again,
        // and its stop of the chat is on its way.
        final stop = Completer<void>();
        final requested = <String>[];
        api
          ..away = false
          ..stopsRefused = false
          ..taskIds = const <String>[]
          ..holdChatStop = stop
          ..dio.interceptors.clear()
          ..dio.httpClientAdapter = _CompletionRoute(api, requested);
        unawaited(
          container
              .read(chatMessagesProvider.notifier)
              .settlePendingCancellation(
                chatId: 'chat-1',
                database: db,
                api: api,
                authSessionEpoch: container.read(
                  openWebUiAuthSessionEpochProvider,
                ),
              )!,
        );
        async.flushMicrotasks();
        check(api.chatStopHeld).isTrue();

        unawaited(
          api.sendMessageSession(
            messages: const [
              {'role': 'user', 'content': 'And the squall?'},
            ],
            model: 'gale-model',
            conversationId: 'chat-1',
            responseMessageId: 'assistant-next',
          ),
        );
        async.elapse(Duration.zero);
        check(requested).isEmpty();
        stop.complete();
        async.elapse(Duration.zero);

        check(requested).deepEquals(['chat-1']);
        check(api.taskIds).deepEquals(['task-next']);
      });
    });

    // Open WebUI stores no temporary chat, and its stop there finishes no
    // stored answer.
    for (final (label, chatId, admits, chatStops) in [
      (
        'a temporary chat, which the server stores no copy of, stops it',
        'local:gale-draft',
        true,
        1,
      ),
      (
        'a saved chat whose copy the server refuses to read, stays owed',
        'chat-1',
        false,
        0,
      ),
    ]) {
      test('a Stop asked again with nothing running, in $label', () {
        fakeAsync((async) {
          final api = _FakeApiService(_chat([question]));
          final (notifier: _, :db, :container) = streamHere(
            async,
            api,
            'Gales veer',
            chatId: chatId,
          );
          api
            ..away = true
            ..readFailures = 1
            ..stopsRefused = true;
          unawaited(container.read(stopGenerationSettledProvider)());
          async.flushMicrotasks();
          final chatStopsBefore = api.chatStops;

          // The server is back, storing neither chat.
          api
            ..away = false
            ..stopsRefused = false
            ..taskIds = const <String>[]
            ..server = FakeOpenWebUiServer(nowEpochSeconds: () => 7000);
          bool? admitted;
          unawaited(
            container
                .read(chatMessagesProvider.notifier)
                .settlePendingCancellation(
                  chatId: chatId,
                  database: db,
                  api: api,
                  authSessionEpoch: container.read(
                    openWebUiAuthSessionEpochProvider,
                  ),
                )!
                .then((ok) => admitted = ok),
          );
          async.flushMicrotasks();

          check(admitted).equals(admits);
          check(api.chatStops - chatStopsBefore).equals(chatStops);
        });
      });
    }

    for (final (label, running) in [
      ('the answer\'s task still running', ['task-1']),
      ('another device\'s task alone running', ['task-elsewhere']),
    ]) {
      test('a Stop asked again while another account signs in sends nothing '
          'as that account, and stays owed, with $label', () {
        fakeAsync((async) {
          final api = _FakeApiService(_chat([question]))
            ..updateAuthToken('session-a');
          final (notifier: _, :db, :container) = streamHere(
            async,
            api,
            'Gales veer',
          );
          api
            ..away = true
            ..readFailures = 1
            ..stopsRefused = true;
          unawaited(container.read(stopGenerationSettledProvider)());
          async.flushMicrotasks();
          final chatStopsBefore = api.chatStops;

          // The server is back. Another account signs in once the retry has
          // read the chat's tasks.
          api
            ..away = false
            ..stopsRefused = false
            ..taskIds = running
            ..afterTaskList = () => api.updateAuthToken('session-b');
          bool? admitted;
          unawaited(
            container
                .read(chatMessagesProvider.notifier)
                .settlePendingCancellation(
                  chatId: 'chat-1',
                  database: db,
                  api: api,
                  authSessionEpoch: container.read(
                    openWebUiAuthSessionEpochProvider,
                  ),
                )!
                .then((ok) => admitted = ok),
          );
          async.flushMicrotasks();

          check(api.sentAs).not((it) => it.contains('session-b'));
          check(api.chatStops - chatStopsBefore).equals(0);
          check(admitted).equals(false);
        });
      });
    }

    test('a Stop the server did not take asks for a drain of its store once '
        'its answer is stored here', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (notifier: _, :db, :container) = streamHere(
          async,
          api,
          'Gales veer',
        );
        final engine = container.read(
          syncEngineProvider.notifier,
        ) as _DrainRecordingSyncEngine;
        api
          ..away = true
          ..readFailures = 1
          ..stopsRefused = true;
        unawaited(container.read(stopGenerationSettledProvider)());
        async.flushMicrotasks();

        check(
          (storedAnswer(async, db)['metadata']
              as Map?)?[kStoppedHereMetadataKey],
        ).equals(true);
        check(engine.drained).isNotEmpty();
        check(engine.drained.every((it) => identical(it, db))).isTrue();
      });
    });

    test('a Stop the server did not take stores its answer and queues its '
        "chat's update together, or neither", () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (notifier: _, :db, :container) = streamHere(
          async,
          api,
          'Gales veer',
        );
        bool updateQueued() {
          var queued = false;
          unawaited(
            db.outboxDao
                .activeForChat('chat-1')
                .then(
                  (ops) => queued = ops.any(
                    (op) => op.kind == OutboxKind.updateChat.name,
                  ),
                ),
          );
          async.flushMicrotasks();
          return queued;
        }

        final before = storedAnswer(async, db);
        // The store takes the answer but nothing for its outbox.
        unawaited(
          db.customStatement(
            'CREATE TEMP TRIGGER outbox_refused BEFORE INSERT ON outbox_ops '
            "BEGIN SELECT RAISE(ABORT, 'outbox refused'); END",
          ),
        );
        async.flushMicrotasks();
        api
          ..away = true
          ..readFailures = 1
          ..stopsRefused = true;
        unawaited(container.read(stopGenerationSettledProvider)());
        async.flushMicrotasks();

        check(storedAnswer(async, db)).deepEquals(before);
        check(updateQueued()).isFalse();

        unawaited(db.customStatement('DROP TRIGGER outbox_refused'));
        async.flushMicrotasks();
        bool? stored;
        unawaited(
          container
              .read(chatMessagesProvider.notifier)
              .settlePendingStoppedAnswers(
                chatId: 'chat-1',
                database: db,
                api: api,
                authSessionEpoch: container.read(
                  openWebUiAuthSessionEpochProvider,
                ),
              )!
              .then((ok) => stored = ok),
        );
        async.flushMicrotasks();

        check(stored).equals(true);
        check(storedAnswer(async, db))
          ..has((it) => it['content'], 'content').equals('Gales veer')
          ..has(
            (it) => (it['metadata'] as Map?)?[kStoppedHereMetadataKey],
            'stopped here',
          ).equals(true);
        check(updateQueued()).isTrue();
      });
    });

    test('a Stop while the server runs the answer\'s task leaves the answer '
        'to the server\'s own save', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]));
        final (notifier: _, :db, :container) = streamHere(
          async,
          api,
          'Gales veer',
        );
        // The task runs as Stop is pressed. Its save of the stopped answer
        // lands after the stop is answered, so the copy still reads empty.
        api.conversation = _chat([
          question,
          _message(answerId, 'assistant', '').copyWith(metadata: unfinished),
        ]);
        var settled = false;
        unawaited(
          container
              .read(stopGenerationSettledProvider)()
              .then((_) => settled = true),
        );
        async.flushMicrotasks();
        check(settled).isTrue();

        check(storedAnswer(async, db))
          ..has((it) => it['content'], 'content').equals('')
          ..has((it) => it['done'], 'done').isNull();
      });
    });
  });

  group("a failed relay to one of the user's devices", () {
    // The answer says itself that one of the user's devices was asked: the
    // model list, which may load after the chat opens, or never, is not.
    for (final (label, socketConnected, listedLater)
        in <(String, bool, List<Model>?)>[
          (
            'its failure arrives while the model list loads',
            true,
            [_deviceModel],
          ),
          (
            'only the poll sees it, and the model list never loads',
            false,
            null,
          ),
        ]) {
      test('a resumed answer from a device keeps its relay warning: '
          '$label', () async {
        final serverCopy = _message(
          'assistant-1',
          'assistant',
          'A',
        ).copyWith(model: _deviceModel.id);
        final opened = [
          _message('user-1', 'user', 'Hi'),
          serverCopy.copyWith(
            metadata: const <String, dynamic>{kCompletionViaTetherKey: true},
          ),
        ];
        final socket = socketConnected ? _FakeSocketService() : null;
        final api = _FakeApiService(_chat([opened.first, serverCopy]))
          ..taskIds = ['task-1'];
        final listed = Completer<List<Model>>();
        final container = _openChatContainer(
          api: api,
          socket: socket,
          listed: listed.future,
        );

        check(container.read(chatMessagesProvider)).isEmpty();
        final notifier = container.read(chatMessagesProvider.notifier);
        container.read(activeConversationProvider.notifier).set(_chat(opened));
        await pumpEventQueue();

        // The relay broke after part of the answer was written. Open WebUI
        // reports it in its generic words and saves them with that part.
        socket?.emitChatEvent(
          type: 'chat:message:error',
          payload: {
            'chat_id': 'chat-1',
            'error': {'content': _generic},
            'done': true,
          },
          messageId: 'assistant-1',
        );
        api
          ..taskIds = const <String>[]
          ..conversation = _chat([
            opened.first,
            serverCopy.copyWith(
              content: 'A partial answer',
              error: const ChatMessageError(content: _generic),
            ),
          ]);
        notifier.debugCancelRemoteTaskMonitorTimer();
        check(notifier.debugTaskStatusCheckInFlight).isFalse();
        await notifier.debugSyncRemoteTaskStatus();
        if (listedLater != null) listed.complete(listedLater);
        await pumpEventQueue();

        final answer = container.read(chatMessagesProvider).last;
        check(answer.isStreaming).isFalse();
        check(answer.error?.relay).equals(TetherRelayFailure.interrupted);
      });
    }

    // A comparison's answers, or a regeneration's: the server's copy keeps
    // the answers the chat does not open on among the versions of the one
    // it does.
    for (final kept in ['among its versions', 'on screen beside it']) {
      test("a device's failed answer keeps its relay when the server's copy "
          'of the chat is read again with it among the versions of another '
          '(this device kept it $kept)', () async {
        final question = _message('user-1', 'user', 'Compare');
        final failed = ChatMessageVersion(
          id: 'answer-b',
          content: '',
          timestamp: DateTime.utc(2026, 11, 20),
          model: _deviceModel.id,
          error: const ChatMessageError(
            content: _generic,
            relay: TetherRelayFailure.interrupted,
          ),
        );
        final shown = _message('answer-a', 'assistant', 'An answer');
        final container = _openChatContainer(
          api: _FakeApiService(_chat(const [])),
        );
        container.read(chatMessagesProvider);
        container
            .read(activeConversationProvider.notifier)
            .set(
              _chat([
                question,
                if (kept == 'among its versions')
                  shown.copyWith(versions: [failed])
                else ...[
                  shown,
                  _message(
                    'answer-b',
                    'assistant',
                    '',
                  ).copyWith(model: _deviceModel.id, error: failed.error),
                ],
              ]),
            );
        await pumpEventQueue();

        // Open WebUI's copy keeps the same error, with no relay.
        container
            .read(activeConversationProvider.notifier)
            .set(
              _chat([
                question,
                shown.copyWith(
                  content: 'An answer, finished',
                  versions: [
                    failed.copyWith(
                      error: const ChatMessageError(content: _generic),
                    ),
                  ],
                ),
              ]),
            );
        await pumpEventQueue();

        final answer = container.read(chatMessagesProvider).last;
        check(answer.content).equals('An answer, finished');
        check(answer.versions.single.error?.relay)
            .equals(TetherRelayFailure.interrupted);
      });
    }

    test("a device's answer stays one among another's versions", () async {
      final question = _message('user-1', 'user', 'Compare');
      final shown = _message('answer-a', 'assistant', 'An answer');
      final running = ChatMessageVersion(
        id: 'answer-b',
        content: 'Part of',
        timestamp: DateTime.utc(2026, 11, 20),
        model: _deviceModel.id,
      );
      final container = _openChatContainer(
        api: _FakeApiService(_chat(const [])),
      );
      container.read(chatMessagesProvider);
      final opened = container.read(activeConversationProvider.notifier)
        ..set(
          _chat([
            question,
            shown,
            _message('answer-b', 'assistant', running.content).copyWith(
              model: _deviceModel.id,
              metadata: const <String, dynamic>{kCompletionViaTetherKey: true},
            ),
          ]),
        );
      await pumpEventQueue();

      // Open WebUI's copy keeps the device's answer, with no error yet, among
      // the versions of the other; the relay fails after that.
      opened.set(
        _chat([
          question,
          shown.copyWith(versions: [running]),
        ]),
      );
      await pumpEventQueue();
      opened.set(
        _chat([
          question,
          shown.copyWith(
            content: 'An answer, finished',
            versions: [
              running.copyWith(
                error: const ChatMessageError(content: _generic),
              ),
            ],
          ),
        ]),
      );
      await pumpEventQueue();

      final answer = container.read(chatMessagesProvider).last;
      check(answer.content).equals('An answer, finished');
      check(answer.versions.single.error?.relay)
          .equals(TetherRelayFailure.interrupted);
    });
  });
}
