/// CDT-RFC-001 §11 Phase 1 acceptance tests for the read-path inversion.
///
/// (a) Airplane-mode cold start: a previously-synced database renders the
///     conversation list and full chat bodies with a SyncApiClient that
///     throws on every call and no ApiService.
/// (c) Edit-on-server -> next requestPull -> the list row and the open-chat
///     body both update.
/// (d) 1,000-chat pull: the narrow list stream emits at most
///     changedChats + 1 times (one emission per per-chat transaction).
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/chats_dao.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/local_conversation_loader.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/pull_sync.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

class _AirplaneModeSyncApiClient implements SyncApiClient {
  int calls = 0;

  Never _offline() {
    calls++;
    throw StateError('network unreachable (airplane mode)');
  }

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) async =>
      _offline();

  @override
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page) async =>
      _offline();

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async => _offline();

  @override
  Future<(List<Map<String, dynamic>>, bool)> getFoldersRaw() async =>
      _offline();

  // Phase 1 read-path test: every network call (read or the Phase 2 write
  // extensions) must throw as if offline. Funnel the unimplemented write
  // methods through [_offline] so this airplane-mode double stays valid as the
  // [SyncApiClient] interface grows without re-listing each method.
  @override
  dynamic noSuchMethod(Invocation invocation) => _offline();
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

  Map<String, dynamic> blobFor(String id, {String content = 'hello'}) => {
    'title': 'Title $id',
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

  ProviderContainer makeContainer(SyncApiClient? client) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(null),
        syncApiClientProvider.overrideWith((ref) => client),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('waitFor timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('acceptance (a): airplane-mode cold start renders list and chats from '
      'the previously-synced database', () async {
    // 1. Online session: pull against the fake server.
    final server = FakeOpenWebUiServer();
    for (var i = 1; i <= 3; i++) {
      server.seedChat(
        id: 'chat-$i',
        blob: blobFor('chat-$i', content: 'message body $i'),
        createdAt: 100 + i,
        updatedAt: 100 + i,
      );
    }
    server.seedFolder('folder-1');
    final pull = PullSync(
      client: FakeSyncApiClient(server),
      db: db,
      locks: ConversationLocks(),
    );
    check((await pull.run()).success).isTrue();

    // 2. Cold start with no network at all: every sync call throws and the
    //    ApiService is gone.
    final offlineClient = _AirplaneModeSyncApiClient();
    final container = makeContainer(offlineClient);

    final conversations = await container.read(conversationsProvider.future);
    check(
      conversations.map((c) => c.id),
    ).deepEquals(['chat-3', 'chat-2', 'chat-1']);

    final folders = await container.read(foldersProvider.future);
    check(folders.map((f) => f.id)).deepEquals(['folder-1']);

    // Any chat is fully readable, message bodies included.
    for (var i = 1; i <= 3; i++) {
      final conversation = await loadLocalConversation(container, 'chat-$i');
      check(conversation).isNotNull();
      check(conversation!.messages.single.content).equals('message body $i');
    }

    // Pulling while offline fails without corrupting the readable state.
    final result = await container
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'airplane-mode');
    check(result?.success ?? false).isFalse();
    check(offlineClient.calls).isGreaterOrEqual(1);
    final after = container.read(conversationsProvider).requireValue;
    check(after.map((c) => c.id)).deepEquals(['chat-3', 'chat-2', 'chat-1']);
  });

  test('acceptance (c): edit-on-server then requestPull updates the list row '
      'and the open chat body', () async {
    final server = FakeOpenWebUiServer();
    server.seedChat(
      id: 'chat-1',
      blob: blobFor('chat-1', content: 'original body'),
      createdAt: 100,
      updatedAt: 100,
    );
    final client = FakeSyncApiClient(server);
    final container = makeContainer(client);

    final result = await container
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'initial');
    check(result?.success ?? false).isTrue();

    await waitFor(() {
      final state = container.read(conversationsProvider);
      return (state.asData?.value ?? const []).isNotEmpty;
    });
    check(
      container.read(conversationsProvider).requireValue.single.title,
    ).equals('Title chat-1');
    final before = await loadLocalConversation(container, 'chat-1');
    check(before!.messages.single.content).equals('original body');

    // Edit on the server (another client renamed it and replaced the body).
    server.seedChat(
      id: 'chat-1',
      blob: {
        ...blobFor('chat-1', content: 'edited body'),
        'title': 'Edited title',
      },
      createdAt: 100,
      updatedAt: 200,
    );

    final second = await container
        .read(syncEngineProvider.notifier)
        .requestPull(reason: 'edit');
    check(second?.success ?? false).isTrue();

    await waitFor(() {
      final state = container.read(conversationsProvider);
      final list = state.asData?.value ?? const [];
      return list.isNotEmpty && list.single.title == 'Edited title';
    });
    final after = await loadLocalConversation(container, 'chat-1');
    check(after!.messages.single.content).equals('edited body');
  });

  test('acceptance (d): a 1,000-chat pull emits at most changedChats + 1 '
      'narrow list emissions', () async {
    final server = FakeOpenWebUiServer();
    const chatCount = 1000;
    for (var i = 1; i <= chatCount; i++) {
      final id = 'chat-${i.toString().padLeft(4, '0')}';
      server.seedChat(
        id: id,
        blob: blobFor(id),
        createdAt: 1000 + i,
        updatedAt: 1000 + i,
      );
    }

    final emissions = <List<ChatListEntry>>[];
    final subscription = db.chatsDao.watchChatList().listen(emissions.add);
    addTearDown(subscription.cancel);
    await waitFor(() => emissions.isNotEmpty);
    final baseline = emissions.length;

    final pull = PullSync(
      client: FakeSyncApiClient(server),
      db: db,
      locks: ConversationLocks(),
    );
    final result = await pull.run();

    check(result.success).isTrue();
    check(result.changedChats).equals(chatCount);
    await waitFor(
      () => emissions.isNotEmpty && emissions.last.length == chatCount,
    );
    // Let any straggling (incorrect) emissions surface before counting.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // One emission per per-chat transaction at most (REQ §10.1 jank proxy).
    check(
      because: 'REQ §10.1: at most one list emission per per-chat merge',
      emissions.length - baseline,
    ).isLessOrEqual(chatCount + 1);
    check(emissions.last.length).equals(chatCount);
  });
}
