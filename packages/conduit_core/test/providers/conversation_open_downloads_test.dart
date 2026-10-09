import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/local_conversation_loader.dart'
    show kOpenRefreshDirectPullMaxPayloadLength;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _NoActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

/// Records the background refresh an open schedules, without any network.
final class _RecordingSyncEngine extends SyncEngine {
  _RecordingSyncEngine(this.pulls, this.cycles);

  final List<String> pulls;
  final List<String> cycles;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<Conversation?> pullChatNow(String chatId) async {
    pulls.add(chatId);
    return null;
  }

  @override
  Future<PullResult?> requestPull({required String reason}) async {
    cycles.add(reason);
    return null;
  }
}

/// Counts direct fetches; the open path should only use them as a fallback.
final class _CountingApi extends ApiService {
  _CountingApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server-a',
          name: 'server-a',
          url: 'https://server-a.example.test',
        ),
        workerManager: WorkerManager(),
      );

  int getConversationCalls = 0;

  @override
  Future<Conversation> getConversation(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    getConversationCalls++;
    return Conversation(
      id: id,
      title: 'Direct fetch',
      createdAt: DateTime.utc(2026, 10, 9),
      updatedAt: DateTime.utc(2026, 10, 9),
    );
  }
}

User _user(String id) =>
    User(id: id, username: id, email: '$id@example.test', role: 'user');

Map<String, dynamic> _blob(String id, {String content = 'hello'}) => {
  'title': 'Title $id',
  'models': ['llama3'],
  'history': {
    'messages': {
      '$id-m1': {
        'id': '$id-m1',
        'parentId': null,
        'childrenIds': <String>[],
        'role': 'user',
        'content': content,
        'timestamp': 100,
      },
    },
    'currentId': '$id-m1',
  },
};

void main() {
  late AppDatabase db;
  late AppDatabase directDb;
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late _CountingApi api;
  late bool previousWarning;

  setUpAll(() {
    previousWarning = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarning;
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
    server = FakeOpenWebUiServer();
    client = FakeSyncApiClient(server);
    api = _CountingApi();
  });
  tearDown(() async {
    await db.close();
    await directDb.close();
  });

  ProviderContainer open({
    String currentUserId = FakeOpenWebUiServer.userId,
    bool useSyncClient = true,
    SyncEngine Function()? engine,
  }) {
    final container = ProviderContainer(
      overrides: [
        ...openWebUiStorageOpenOverrides(database: db),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        activeConversationProvider.overrideWith(_NoActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        currentUserProvider2.overrideWithValue(_user(currentUserId)),
        apiServiceProvider.overrideWithValue(api),
        socketServiceProvider.overrideWithValue(null),
        syncApiClientProvider.overrideWith(
          (ref) => useSyncClient ? client : null,
        ),
        if (engine != null) syncEngineProvider.overrideWith(engine),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  // Lets any fire-and-forget refresh the open scheduled reach the fakes.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  Future<void> store(String id, {String content = 'hello'}) async {
    server.seedChat(
      id: id,
      blob: _blob(id, content: content),
      createdAt: 100,
      updatedAt: 150,
    );
    final stored = await PullSync(
      client: FakeSyncApiClient(server),
      db: db,
      locks: ConversationLocks(),
    ).pullChat(id);
    check(stored).isNotNull();
  }

  group('first open of a chat with no stored body', () {
    test('downloads it once and stores it for the next open', () async {
      server.seedChat(
        id: 'chat-1',
        blob: _blob('chat-1'),
        createdAt: 100,
        updatedAt: 150,
      );
      final container = open();

      final loaded = await container.read(
        loadConversationProvider('chat-1').future,
      );
      await settle();

      check(loaded.messages.single.content).equals('hello');
      check(chatStorageKindOf(loaded)).equals(ChatStorageKind.openWebUi);
      check(client.chatFetchStarts).deepEquals(['chat-1']);
      check(api.getConversationCalls).equals(0);
      check((await db.chatsDao.getChat('chat-1'))!.bodySynced).isTrue();
    });

    test(
      'downloads another user\'s shared chat once without storing it',
      () async {
        server.seedChat(
          id: 'shared-1',
          blob: _blob('shared-1'),
          createdAt: 100,
          updatedAt: 150,
        );
        final container = open(currentUserId: 'someone-else');

        final loaded = await container.read(
          loadConversationProvider('shared-1').future,
        );
        await settle();

        check(loaded.userId).equals(FakeOpenWebUiServer.userId);
        check(client.chatFetchStarts).deepEquals(['shared-1']);
        check(api.getConversationCalls).equals(0);
        check(await db.chatsDao.getChat('shared-1')).isNull();
      },
    );

    test(
      'falls back to a direct fetch when the sync engine has no client',
      () async {
        final container = open(useSyncClient: false);

        final loaded = await container.read(
          loadConversationProvider('chat-1').future,
        );
        await settle();

        check(loaded.title).equals('Direct fetch');
        check(api.getConversationCalls).equals(1);
      },
    );
  });

  group('reopening a stored chat', () {
    late List<String> pulls;
    late List<String> cycles;

    setUp(() {
      pulls = <String>[];
      cycles = <String>[];
    });

    ProviderContainer openRecording() =>
        open(engine: () => _RecordingSyncEngine(pulls, cycles));

    test(
      'a large clean chat is checked with a pull cycle, not re-downloaded',
      () async {
        await store(
          'large',
          content: 'x' * (kOpenRefreshDirectPullMaxPayloadLength + 1),
        );
        final container = openRecording();

        final loaded = await container.read(
          loadConversationProvider('large').future,
        );
        await settle();

        check(loaded.messages.single.content.length)
            .equals(kOpenRefreshDirectPullMaxPayloadLength + 1);
        check(cycles).deepEquals(['open-large-chat']);
        check(pulls).isEmpty();
      },
    );

    test(
      'a small chat is pulled directly, as a pull costs less than a cycle',
      () async {
        await store('small');
        final container = openRecording();

        await container.read(loadConversationProvider('small').future);
        await settle();

        check(pulls).deepEquals(['small']);
        check(cycles).isEmpty();
      },
    );

    test('a large chat with unsent local edits is pulled directly', () async {
      await store(
        'edited',
        content: 'x' * (kOpenRefreshDirectPullMaxPayloadLength + 1),
      );
      await (db.update(db.chats)..where((chat) => chat.id.equals('edited')))
          .write(const ChatsCompanion(dirty: Value(true)));
      final container = openRecording();

      await container.read(loadConversationProvider('edited').future);
      await settle();

      check(pulls).deepEquals(['edited']);
      check(cycles).isEmpty();
    });
  });
}
