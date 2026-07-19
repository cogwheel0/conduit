import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/direct_connections/direct_connections.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/openwebui_storage_test_overrides.dart';

class _TestActiveConversationNotifier extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _FixedModels extends Models {
  _FixedModels(this.models);

  final List<Model> models;

  @override
  Future<List<Model>> build() async => models;
}

class _DeferredModels extends Models {
  _DeferredModels(this.models);

  final Future<List<Model>> models;

  @override
  Future<List<Model>> build() => models;
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
    bool keepsAliveInBackground = false,
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
  int getTaskIdsCalls = 0;

  @override
  Future<Conversation> getConversation(String id) async {
    getConversationCalls++;
    return _conversation;
  }

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async {
    getTaskIdsCalls++;
    return taskIds;
  }
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

({DirectModelRegistry registry, Model model, String wireModelId})
_serverDirectModel() {
  final profile = DirectConnectionProfile(
    id: 'server-direct-profile',
    name: 'Server direct connection',
    adapterKey: kOpenAiCompatibleAdapterKey,
    baseUrl: 'https://provider.example.test/v1',
    modelIdPrefix: 'shared',
  );
  final registry = DirectModelRegistry();
  final model = registry
      .replaceProfileModels(
        profile,
        <DirectRemoteModel>[DirectRemoteModel(id: 'model')],
        source: DirectModelSource.openWebUi,
        openWebUiUrlIndex: 2,
      )
      .single;
  return (registry: registry, model: model, wireModelId: 'shared.model');
}

ProviderContainer _modelRebindContainer({
  required DirectModelRegistry registry,
  required List<Model> models,
}) => ProviderContainer(
  overrides: [
    ...openWebUiStorageOpenOverrides(),
    activeConversationProvider.overrideWith(
      _TestActiveConversationNotifier.new,
    ),
    apiServiceProvider.overrideWithValue(null),
    socketServiceProvider.overrideWithValue(null),
    directModelRegistryProvider.overrideWithValue(registry),
    modelsProvider.overrideWith(() => _FixedModels(models)),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatMessagesNotifier remote sync', () {
    test(
      'a slower model lookup cannot overwrite a newer conversation',
      () async {
        final models = Completer<List<Model>>();
        const priorSelection = Model(
          id: 'previous-model',
          name: 'Previous model',
        );
        const modelA = Model(id: 'model-a', name: 'Model A');
        const modelB = Model(id: 'model-b', name: 'Model B');
        final container = ProviderContainer(
          overrides: [
            ...openWebUiStorageOpenOverrides(),
            activeConversationProvider.overrideWith(
              _TestActiveConversationNotifier.new,
            ),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            modelsProvider.overrideWith(() => _DeferredModels(models.future)),
          ],
        );
        addTearDown(container.dispose);
        container.read(chatMessagesProvider);
        container.read(selectedModelProvider.notifier).set(priorSelection);

        Conversation conversation(String id, String model) =>
            withChatStorageProvenance(
              _conversation(
                id,
                const <ChatMessage>[],
                DateTime.utc(2026, 7, 15),
              ).copyWith(model: model),
              ChatStorageKind.openWebUi,
            );

        container
            .read(activeConversationProvider.notifier)
            .set(conversation('chat-a', modelA.id));
        await pumpMicrotasks();
        container
            .read(activeConversationProvider.notifier)
            .set(conversation('chat-b', modelB.id));
        await pumpMicrotasks();

        models.complete(const <Model>[modelA, modelB]);
        await pumpMicrotasks();
        await pumpMicrotasks();

        check(container.read(selectedModelProvider)).identicalTo(modelB);
      },
    );

    test(
      'cold reopen rebinds an Open WebUI wire model to its trusted direct model',
      () async {
        final direct = _serverDirectModel();
        const priorSelection = Model(
          id: 'previous-model',
          name: 'Previous model',
        );
        final container = _modelRebindContainer(
          registry: direct.registry,
          models: <Model>[direct.model],
        );
        addTearDown(container.dispose);
        container.read(chatMessagesProvider);
        container.read(selectedModelProvider.notifier).set(priorSelection);

        container
            .read(activeConversationProvider.notifier)
            .set(
              withChatStorageProvenance(
                _conversation(
                  'server-direct-chat',
                  const <ChatMessage>[],
                  DateTime.utc(2026, 7, 15),
                ).copyWith(model: direct.wireModelId),
                ChatStorageKind.openWebUi,
              ),
            );
        await pumpMicrotasks();
        await pumpMicrotasks();

        check(direct.model.id).not((it) => it.equals(direct.wireModelId));
        check(container.read(selectedModelProvider)).identicalTo(direct.model);
        check(
          direct.registry.resolve(container.read(selectedModelProvider)!),
        ).isNotNull();
      },
    );

    test(
      'cold reopen prefers trusted direct binding over a same-id server model',
      () async {
        final direct = _serverDirectModel();
        final serverCollision = Model(
          id: direct.wireModelId,
          name: 'Untrusted server collision',
        );
        final container = _modelRebindContainer(
          registry: direct.registry,
          models: <Model>[serverCollision, direct.model],
        );
        addTearDown(container.dispose);
        container.read(chatMessagesProvider);
        container.read(selectedModelProvider.notifier).set(serverCollision);

        container
            .read(activeConversationProvider.notifier)
            .set(
              withChatStorageProvenance(
                _conversation(
                  'server-direct-collision-chat',
                  const <ChatMessage>[],
                  DateTime.utc(2026, 7, 15),
                ).copyWith(model: direct.wireModelId),
                ChatStorageKind.openWebUi,
              ),
            );
        await pumpMicrotasks();
        await pumpMicrotasks();

        check(container.read(selectedModelProvider)).identicalTo(direct.model);
        check(
          container.read(selectedModelProvider),
        ).not((it) => it.identicalTo(serverCollision));
      },
    );

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
          ...openWebUiStorageOpenOverrides(),
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
            ...openWebUiStorageOpenOverrides(),
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
          ...openWebUiStorageOpenOverrides(),
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
          ...openWebUiStorageOpenOverrides(),
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
            ...openWebUiStorageOpenOverrides(),
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
        final api = _FakeApiService(
          _conversation('chat-1', messages, timestamp),
        )..taskIds = ['task-1'];

        final container = ProviderContainer(
          overrides: [
            ...openWebUiStorageOpenOverrides(),
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
          ...openWebUiStorageOpenOverrides(),
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
          ...openWebUiStorageOpenOverrides(),
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

    test('resume poll adopts server content matched by the bound foreign '
        'message id (socket bound a server id then died)', () async {
      final timestamp = DateTime.now();
      final opened = [
        _userMessage('user-1', 'Hi', timestamp),
        _assistantMessage('assistant-local', 'Partial', timestamp),
      ];
      // The server persists the message under its OWN (foreign) id, not the
      // local placeholder id.
      final grown = [
        _userMessage('user-1', 'Hi', timestamp),
        _assistantMessage(
          'server-foreign',
          'Partial answer that grew',
          timestamp,
        ),
      ];
      final api = _FakeApiService(_conversation('chat-1', grown, timestamp))
        ..taskIds = ['task-1'];

      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
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
      check(
        container.read(chatMessagesProvider).last.content,
      ).equals('Partial');

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
    });

    test('temporary chats are never probed for active tasks', () async {
      final timestamp = DateTime.now();
      final messages = [
        _userMessage('user-1', 'Hi', timestamp),
        _assistantMessage('assistant-1', 'Partial', timestamp),
      ];
      final api = _FakeApiService(
        _conversation('local:tmp', messages, timestamp),
      )..taskIds = ['task-1'];

      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
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

    test('Hermes tails never start OpenWebUI task recovery, including in an '
        'OpenWebUI-backed chat', () async {
      final timestamp = DateTime.now();
      final api = _FakeApiService(
        _conversation('unused', const <ChatMessage>[], timestamp),
      );
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(),
          activeConversationProvider.overrideWith(
            () => _TestActiveConversationNotifier(),
          ),
          socketServiceProvider.overrideWithValue(null),
          apiServiceProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(chatMessagesProvider.notifier);
      final active = container.read(activeConversationProvider.notifier);
      final nativeHermesTail = ChatMessage(
        id: 'native-hermes-assistant',
        role: 'assistant',
        content: 'Working',
        timestamp: timestamp,
        isStreaming: true,
        metadata: const <String, dynamic>{'transport': kHermesTransport},
      );
      active.set(
        Conversation(
          id: 'native-hermes-chat',
          title: 'Native Hermes',
          createdAt: timestamp,
          updatedAt: timestamp,
          messages: <ChatMessage>[nativeHermesTail],
          metadata: const <String, dynamic>{'backend': 'hermes'},
        ),
      );
      await pumpMicrotasks();
      await pumpMicrotasks();

      check(notifier.debugHasOpenWebUiTaskRecoverableTail).isFalse();
      await notifier.debugSyncRemoteTaskStatus();
      check(api.getTaskIdsCalls).equals(0);

      final mixedHermesTail = nativeHermesTail.copyWith(
        id: 'mixed-hermes-assistant',
      );
      active.set(
        withChatStorageProvenance(
          Conversation(
            id: 'openwebui-chat-with-hermes-turn',
            title: 'Mixed transport',
            createdAt: timestamp,
            updatedAt: timestamp,
            messages: <ChatMessage>[mixedHermesTail],
          ),
          ChatStorageKind.openWebUi,
        ),
      );
      await pumpMicrotasks();
      await pumpMicrotasks();

      check(notifier.debugHasOpenWebUiTaskRecoverableTail).isFalse();
      await notifier.debugSyncRemoteTaskStatus();
      check(api.getTaskIdsCalls).equals(0);

      final completedMixedHermesTail = mixedHermesTail.copyWith(
        isStreaming: false,
      );
      active.set(
        withChatStorageProvenance(
          Conversation(
            id: 'openwebui-chat-with-completed-hermes-turn',
            title: 'Completed mixed transport',
            createdAt: timestamp,
            updatedAt: timestamp,
            messages: <ChatMessage>[completedMixedHermesTail],
          ),
          ChatStorageKind.openWebUi,
        ),
      );
      await pumpMicrotasks();
      await pumpMicrotasks();

      // Active-on-open must not reinterpret a completed Hermes turn as an
      // OpenWebUI task placeholder merely because its chat is stored there.
      check(container.read(chatMessagesProvider).single.isStreaming).isFalse();
      check(api.getTaskIdsCalls).equals(0);
    });

    test(
      'a genuine OpenWebUI streaming tail still starts task recovery',
      () async {
        final timestamp = DateTime.now();
        final assistant = ChatMessage(
          id: 'openwebui-assistant',
          role: 'assistant',
          content: 'Working',
          timestamp: timestamp,
          isStreaming: true,
          metadata: const <String, dynamic>{'transport': 'taskSocket'},
        );
        final api = _FakeApiService(
          _conversation('openwebui-chat', <ChatMessage>[assistant], timestamp),
        );
        final container = ProviderContainer(
          overrides: [
            ...openWebUiStorageOpenOverrides(),
            activeConversationProvider.overrideWith(
              () => _TestActiveConversationNotifier(),
            ),
            socketServiceProvider.overrideWithValue(null),
            apiServiceProvider.overrideWithValue(api),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(chatMessagesProvider.notifier);
        container
            .read(activeConversationProvider.notifier)
            .set(
              withChatStorageProvenance(
                _conversation('openwebui-chat', <ChatMessage>[
                  assistant,
                ], timestamp).copyWith(
                  // A previous direct turn may leave this transport hint on
                  // the conversation. Explicit OpenWebUI storage still owns
                  // passive/task sync; the tail message selects the transport.
                  metadata: const <String, dynamic>{'backend': 'direct'},
                ),
                ChatStorageKind.openWebUi,
              ),
            );
        await pumpMicrotasks();
        await pumpMicrotasks();
        notifier.debugCancelRemoteTaskMonitorTimer();
        while (notifier.debugTaskStatusCheckInFlight) {
          await pumpMicrotasks();
        }

        check(notifier.debugHasOpenWebUiTaskRecoverableTail).isTrue();
        check(api.getTaskIdsCalls).isGreaterThan(0);
        api.getTaskIdsCalls = 0;
        await notifier.debugSyncRemoteTaskStatus();
        check(api.getTaskIdsCalls).equals(1);
      },
    );

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
            ...openWebUiStorageOpenOverrides(),
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
        check(
          container.read(chatMessagesProvider).last.content,
        ).equals('Final answer');
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
          ...openWebUiStorageOpenOverrides(),
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
            ...openWebUiStorageOpenOverrides(),
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
