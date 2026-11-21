import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_comparison.dart'
    show kMessageServerUnfinishedMetadataKey;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/testing.dart';
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
  }) async => conversation;

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async {
    taskLookups++;
    return taskIds;
  }
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

ProviderContainer _openChatContainer({
  required _FakeApiService api,
  _FakeSocketService? socket,
  Future<List<Model>>? listed,
}) {
  final container = ProviderContainer(
    overrides: [
      secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
      ...openWebUiStorageOpenOverrides(),
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

    test('settles with what streamed here, and the connection lost, once '
        'the server runs no task for it', () {
      fakeAsync((async) {
        final api = _FakeApiService(_chat([question]))..taskIds = ['task-1'];
        final container = _openChatContainer(api: api);
        final notifier = container.read(chatMessagesProvider.notifier);
        container
            .read(activeConversationProvider.notifier)
            .set(_chat([question]));
        async.flushMicrotasks();

        // The answer streams here over the socket, and its task is seen.
        notifier
          ..addMessage(
            _message(
              'assistant-1',
              'assistant',
              '',
            ).copyWith(isStreaming: true),
          )
          ..setSocketSubscriptions('assistant-1', [() {}])
          ..appendToLastMessage('Gales veer as the front');
        async.elapse(Duration.zero);
        check(api.taskLookups).equals(1);
        notifier.debugCancelRemoteTaskMonitorTimer();

        // The server stopped and is back: it runs no task for the chat, and
        // keeps the answer not done and empty, as it was when it stopped.
        api
          ..taskIds = const <String>[]
          ..conversation = _chat([
            question,
            _message('assistant-1', 'assistant', '').copyWith(
              metadata: const <String, dynamic>{
                kMessageServerUnfinishedMetadataKey: true,
              },
            ),
          ]);
        // The socket's own end is waited for first.
        for (var poll = 0; poll < 3; poll++) {
          unawaited(notifier.debugSyncRemoteTaskStatus());
          async.flushMicrotasks();
        }

        final answer = container.read(chatMessagesProvider).last;
        check(answer.isStreaming).isFalse();
        check(answer.content).equals('Gales veer as the front');
        check(answer.error?.content)
            .equals(TemporaryChatResume.connectionLostMessage);
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
