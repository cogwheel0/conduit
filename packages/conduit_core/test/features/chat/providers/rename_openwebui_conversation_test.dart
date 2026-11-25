import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/providers/conversation_title_generation.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/backoff.dart';
import 'package:conduit_core/sync/chat_adapter.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/push_sync.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:conduit_core/testing.dart';

const _chatId = 'chat-1';
const _title = 'The drawer';
const _renamed = 'The shelf question';

/// The title's own requests, against [server]: the rename held at [gate],
/// or refused with [failure].
final class _ServerApi extends ApiService {
  _ServerApi(this.server)
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
        workerManager: WorkerManager(),
      );

  final FakeOpenWebUiServer server;
  Completer<void>? gate;
  final Completer<void> asked = Completer<void>();
  Object? failure;

  @override
  Future<void> updateConversation(
    String id, {
    String? title,
    String? systemPrompt,
    List<String>? models,
    ApiAuthSnapshot? authSnapshot,
  }) async {
    if (!asked.isCompleted) asked.complete();
    await gate?.future;
    final refused = failure;
    if (refused != null) throw refused;
    server.updateChat(id, {'title': title});
  }

  @override
  Future<Map<String, dynamic>?> getChatRaw(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async => server.getChatById(id);

  @override
  Future<String?> generateChatTitle({
    required String model,
    required List<Map<String, dynamic>> messages,
    String? chatId,
    ApiAuthSnapshot? authSnapshot,
  }) async => _renamed;
}

final class _NoModels extends Models {
  @override
  Future<List<Model>> build() async => const [];
}

final class _NoConversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const [];
}

/// Holds the first read of a chat once the server has answered it.
final class _HeldReadClient extends FakeSyncApiClient {
  _HeldReadClient(super.server);

  Future<void>? readGate;
  Completer<void> read = Completer<void>();

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    final answer = await super.getChatRaw(id);
    if (!read.isCompleted) read.complete();
    await readGate;
    return answer;
  }
}

final class _NoCompletions implements RequestCompletionRunner {
  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) => throw StateError('no answer is asked for here');
}

final class _Clock implements SyncClock {
  @override
  int nowEpochSeconds() => 7000;
}

void main() {
  late FakeOpenWebUiServer server;
  late _HeldReadClient client;
  late AppDatabase db;
  late ConversationLocks locks;
  late IdRemapper remapper;
  late PullSync pull;
  late OutboxDrainer drainer;
  late _ServerApi api;
  late ProviderContainer container;

  setUp(() async {
    server = FakeOpenWebUiServer();
    client = _HeldReadClient(server);
    db = AppDatabase(NativeDatabase.memory());
    locks = ConversationLocks();
    remapper = IdRemapper(db);
    pull = PullSync(client: client, db: db, locks: locks, remapper: remapper);
    drainer = OutboxDrainer(
      db: db,
      clock: _Clock(),
      backoff: Backoff(jitter: () => 0.0),
      isOnline: () => true,
      completion: _NoCompletions(),
      adapters: [
        ChatAdapter(
          pull: pull,
          push: PushSync(
            client: client,
            db: db,
            chatLocks: locks,
            folderLocks: FolderLocks(),
            clock: _Clock(),
            remapper: remapper,
          ),
        ),
      ],
    );
    api = _ServerApi(server);
    container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        apiServiceProvider.overrideWithValue(api),
        openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        chatLocksProvider.overrideWithValue(locks),
        modelsProvider.overrideWith(_NoModels.new),
        conversationsProvider.overrideWith(_NoConversations.new),
      ],
    );
    server.seedChat(
      id: _chatId,
      blob: {
        'title': _title,
        'history': {
          'currentId': 'm1',
          'messages': {
            'm1': {
              'id': 'm1',
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'Where did the drawer go?',
              'timestamp': 1000,
            },
          },
        },
      },
      createdAt: 100,
      updatedAt: 100,
    );
    await pull.pullChat(_chatId);
  });

  tearDown(() async {
    container.dispose();
    await remapper.dispose();
    await db.close();
  });

  /// A change of the chat's settings, queued to be saved: the save sends
  /// the whole chat, title included, as stored when it goes.
  Future<void> queueSave() => locks.runExclusive(
    _chatId,
    () => db.chatsDao.patchChatParamsWithOutbox(
      _chatId,
      set: const {'temperature': 0.4},
      updatedAt: 7000,
    ),
  );

  Future<String?> storedTitle() async =>
      (await db.chatsDao.getChat(_chatId))?.title;

  Future<Object?> storedServerTitle() async {
    final row = await db.chatsDao.getChat(_chatId);
    return (jsonDecode(row!.blobMeta) as Map)['blobTitleValue'];
  }

  Object? serverTitle() => server.getChatById(_chatId)!['title'];

  final titleWrites = <(String, Future<void> Function(ProviderContainer))>[
    ('a rename', (c) => renameOpenWebUiConversation(c, _chatId, _renamed)),
    (
      'a generated title',
      (c) => generateConversationTitle(c, _chatId, selectedModelId: 'llama3'),
    ),
  ];
  for (final (name, write) in titleWrites) {
    test('a pull that read the chat before $name does not put the old title '
        'back, nor does the next save', () async {
      final released = Completer<void>();
      client
        ..readGate = released.future
        ..read = Completer<void>();
      final pulling = pull.pullChat(_chatId);
      await client.read.future;

      await write(container);
      released.complete();
      await pulling;

      expect(await storedTitle(), _renamed);
      expect(await storedServerTitle(), _renamed);
      await queueSave();
      await drainer.drain();
      expect(serverTitle(), _renamed);
    });
  }
}
