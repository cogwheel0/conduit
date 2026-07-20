import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/chat_database_repository.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/openwebui_storage_test_overrides.dart';

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _CountingApi extends ApiService {
  _CountingApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  int taskLookups = 0;
  int broadStops = 0;

  @override
  Future<List<String>> getTaskIdsByChat(String chatId) async {
    taskLookups++;
    return const [];
  }

  @override
  Future<void> stopTasksByChat(String chatId) async {
    broadStops++;
  }
}

final class _CountingSocket extends SocketService {
  _CountingSocket()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
      );

  int handlers = 0;

  @override
  SocketEventSubscription addChatEventHandler({
    String? conversationId,
    String? sessionId,
    String? messageId,
    bool requireFocus = true,
    bool keepsAliveInBackground = false,
    required SocketChatEventHandler handler,
  }) {
    handlers++;
    return SocketEventSubscription(() => handlers--);
  }
}

Conversation _conversation(
  String id,
  ChatStorageKind storage,
  String content, {
  bool streaming = false,
}) {
  final now = DateTime.utc(2026, 7, 11);
  return withChatStorageProvenance(
    Conversation(
      id: id,
      title: storage.name,
      createdAt: now,
      updatedAt: now,
      messages: [
        ChatMessage(
          id: '${storage.name}-assistant',
          role: 'assistant',
          content: content,
          timestamp: now,
          isStreaming: streaming,
          metadata: streaming
              ? const {'transport': kDirectTransport}
              : const {},
        ),
      ],
    ),
    storage,
  );
}

ChatRows _rows(String id, String messageId, String content, int updatedAt) {
  return ChatBlobMapper.blobToRows(
    chatId: id,
    blob: {
      'title': id,
      'history': {
        'currentId': messageId,
        'messages': {
          messageId: {
            'id': messageId,
            'parentId': null,
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': content,
            'timestamp': updatedAt,
          },
        },
      },
    },
    title: id,
    createdAt: updatedAt,
    updatedAt: updatedAt,
  );
}

Future<void> _settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 30));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase serverDb;
  late AppDatabase directDb;
  late bool previousDontWarnAboutMultipleDatabases;

  setUpAll(() {
    previousDontWarnAboutMultipleDatabases =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases =
        previousDontWarnAboutMultipleDatabases;
  });

  setUp(() {
    serverDb = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await serverDb.close();
    await directDb.close();
  });

  ProviderContainer containerFor(_CountingApi api, _CountingSocket socket) {
    final container = ProviderContainer(
      overrides: [
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        ...openWebUiStorageOpenOverrides(database: serverDb),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        apiServiceProvider.overrideWithValue(api),
        socketServiceProvider.overrideWithValue(socket),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'same raw id switches state and DB watch by storage provenance',
    () async {
      const id = 'collision';
      await serverDb.chatsDao.upsertServerChat(
        rows: _rows(id, 'server-db', 'server database', 1),
      );
      await directDb.chatsDao.upsertLocalOnlyChat(
        rows: _rows(id, 'direct-db', 'direct database', 2),
      );
      final api = _CountingApi();
      final socket = _CountingSocket();
      final container = containerFor(api, socket);

      container
          .read(activeConversationProvider.notifier)
          .set(_conversation(id, ChatStorageKind.openWebUi, 'server snapshot'));
      expect(
        container.read(chatMessagesProvider).single.content,
        'server snapshot',
      );

      final direct = _conversation(
        id,
        ChatStorageKind.directLocal,
        'direct snapshot',
      );
      container.read(activeConversationProvider.notifier).set(direct);
      expect(
        container.read(chatMessagesProvider).single.content,
        'direct snapshot',
      );
      expect(socket.handlers, 0);

      await directDb.chatsDao.upsertLocalOnlyChat(
        rows: _rows(id, 'direct-new', 'direct refreshed', 3),
      );
      await _settle();
      expect(
        container.read(chatMessagesProvider).single.content,
        'direct refreshed',
      );

      await serverDb.chatsDao.upsertServerChat(
        rows: _rows(id, 'server-new', 'wrong store', 4),
      );
      await _settle();
      expect(
        container.read(chatMessagesProvider).single.content,
        'direct refreshed',
      );
      expect(api.taskLookups, 0);
    },
  );

  test('stopping reserved direct preflight clears UI without server stop', () {
    final api = _CountingApi();
    final socket = _CountingSocket();
    final container = containerFor(api, socket);
    final conversation = _conversation(
      'direct-local:pending',
      ChatStorageKind.directLocal,
      'partial',
      streaming: true,
    );
    container.read(activeConversationProvider.notifier).set(conversation);
    final notifier = container.read(chatMessagesProvider.notifier);
    notifier.setMessages(conversation.messages);
    final assistantId = conversation.messages.single.id;
    final registry = container.read(directRunRegistryProvider);
    final reservation = registry.reserve((
      ownerConversationId: directRunOwnerScopeForTest(container, conversation),
      assistantMessageId: assistantId,
    ), 'profile');

    container.read(stopGenerationProvider)();

    expect(container.read(chatMessagesProvider).single.isStreaming, isFalse);
    expect(registry.isCancelled(reservation), isTrue);
    expect(api.broadStops, 0);
  });

  test('scoped completion cannot finalize a colliding store', () {
    final container = containerFor(_CountingApi(), _CountingSocket());
    const id = 'same-id';
    final direct = _conversation(
      id,
      ChatStorageKind.directLocal,
      'direct stream',
      streaming: true,
    );
    container.read(activeConversationProvider.notifier).set(direct);
    final notifier = container.read(chatMessagesProvider.notifier);
    notifier.setMessages(direct.messages);
    final server = _conversation(
      id,
      ChatStorageKind.openWebUi,
      'server stream',
      streaming: true,
    );
    container.read(activeConversationProvider.notifier).set(server);

    notifier.finishStreamingMessage(
      server.messages.single.id,
      ownerConversationId: ChatStorageIdentity(
        rawId: id,
        storage: ChatStorageKind.directLocal,
      ).scopedId,
      requireConversationOwner: true,
    );

    expect(
      container.read(chatMessagesProvider).single.content,
      'server stream',
    );
    expect(container.read(chatMessagesProvider).single.isStreaming, isTrue);
    notifier.finishStreaming();
  });
}
