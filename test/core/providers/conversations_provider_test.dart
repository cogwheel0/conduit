/// Conversations provider tests on the Drift read substrate
/// (CDT-RFC-001 Phase 1 read-path inversion).
///
/// The provider renders `ChatsDao.watchChatList()`; mutators stay
/// synchronous in memory and persist the same envelope change so the next
/// stream emission agrees. Behavioral pillars carried over from the legacy
/// Hive-backed suite: auth gating, unread/lastReadAt preservation,
/// archived/filtered split, and folder summaries.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/socket_service.dart';
import 'package:conduit/core/sync/pull_sync.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

class _RecordingSyncEngine extends SyncEngine {
  _RecordingSyncEngine(this.pulls);

  final List<String> pulls;

  @override
  Future<PullResult?> requestPull({required String reason}) {
    pulls.add(reason);
    return Future.value(null);
  }
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

  ProviderContainer makeContainer({
    bool authenticated = true,
    List<Override> extraOverrides = const <Override>[],
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        isAuthenticatedProvider2.overrideWithValue(authenticated),
        reviewerModeProvider.overrideWithValue(false),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
        ...extraOverrides,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('waitFor timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<T> waitForAsync<T>(
    Future<T> Function() read, {
    required bool Function(T value) condition,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final value = await read();
      if (condition(value)) return value;
      if (DateTime.now().isAfter(deadline)) {
        fail('waitForAsync timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> seedServerChat(
    String id, {
    required int updatedAt,
    bool pinned = false,
    bool archived = false,
    String? folderId,
    int? lastReadAt,
  }) {
    return db.chatsDao.upsertServerChat(
      rows: ChatBlobMapper.blobToRows(
        chatId: id,
        blob: {
          'title': 'Title $id',
          'history': {
            'messages': {
              '$id-m1': {
                'id': '$id-m1',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'hello from $id',
                'timestamp': updatedAt,
              },
            },
            'currentId': '$id-m1',
          },
        },
        title: 'Title $id',
        folderId: folderId,
        pinned: pinned,
        archived: archived,
        createdAt: updatedAt,
        updatedAt: updatedAt,
      ),
      listLastReadAt: lastReadAt,
    );
  }

  List<String> idsOf(List<Conversation> conversations) =>
      conversations.map((conversation) => conversation.id).toList();

  group('Conversations', () {
    test(
      'unauthenticated build returns empty without touching the database',
      () async {
        final container = makeContainer(authenticated: false);

        final conversations = await container.read(
          conversationsProvider.future,
        );

        check(conversations).isEmpty();
      },
    );

    test('renders chat rows newest-first with no message bodies', () async {
      await seedServerChat('chat-old', updatedAt: 100);
      await seedServerChat('chat-new', updatedAt: 200);
      final container = makeContainer();

      final conversations = await container.read(conversationsProvider.future);

      check(idsOf(conversations)).deepEquals(['chat-new', 'chat-old']);
      // Narrow list projection: summaries never carry message bodies.
      for (final conversation in conversations) {
        check(conversation.messages).isEmpty();
      }
      check(
        conversations.first.updatedAt,
      ).equals(DateTime.fromMillisecondsSinceEpoch(200 * 1000));
    });

    test('later database writes stream into provider state', () async {
      await seedServerChat('chat-1', updatedAt: 100);
      final container = makeContainer();
      await container.read(conversationsProvider.future);

      await seedServerChat('chat-2', updatedAt: 200);

      await waitFor(() {
        final state = container.read(conversationsProvider);
        return idsOf(state.asData?.value ?? const []).contains('chat-2');
      });
      check(
        idsOf(container.read(conversationsProvider).requireValue),
      ).deepEquals(['chat-2', 'chat-1']);
    });

    test('archived/filtered split with pinned-first ordering', () async {
      await seedServerChat('chat-archived', updatedAt: 400, archived: true);
      await seedServerChat('chat-pinned', updatedAt: 100, pinned: true);
      await seedServerChat('chat-regular', updatedAt: 300);
      final container = makeContainer();
      await container.read(conversationsProvider.future);

      final filtered = container.read(filteredConversationsProvider);
      final archived = container.read(archivedConversationsProvider);

      // Pinned first despite the older updatedAt; archived excluded.
      check(idsOf(filtered)).deepEquals(['chat-pinned', 'chat-regular']);
      check(idsOf(archived)).deepEquals(['chat-archived']);
    });

    test('markConversationRead persists a read mark that a stale server value '
        'never lowers', () async {
      await seedServerChat('chat-1', updatedAt: 100);
      final container = makeContainer();
      await container.read(conversationsProvider.future);

      final readAt = DateTime.fromMillisecondsSinceEpoch(500 * 1000);
      container
          .read(conversationsProvider.notifier)
          .markConversationRead('chat-1', readAt);

      // In-memory state updates synchronously.
      check(
        container.read(conversationsProvider).requireValue.single.lastReadAt,
      ).equals(readAt);

      // The row write lands (max() rule in the DAO).
      await waitFor(() {
        return container
                .read(conversationsProvider)
                .requireValue
                .single
                .lastReadAt ==
            readAt;
      });

      // A pull merge carrying an older server read mark cannot lower it.
      await seedServerChat('chat-1', updatedAt: 600, lastReadAt: 50);
      await waitFor(() {
        final current = container
            .read(conversationsProvider)
            .requireValue
            .single;
        return current.updatedAt ==
            DateTime.fromMillisecondsSinceEpoch(600 * 1000);
      });
      check(
        container.read(conversationsProvider).requireValue.single.lastReadAt,
      ).equals(readAt);
    });

    test('markConversationRead never regresses an existing newer mark', () {
      final container = makeContainer();
      final newer = DateTime.fromMillisecondsSinceEpoch(900 * 1000);
      final older = DateTime.fromMillisecondsSinceEpoch(400 * 1000);
      container
          .read(conversationsProvider.notifier)
          .upsertConversation(_conversation('chat-1', lastReadAt: newer));

      container
          .read(conversationsProvider.notifier)
          .markConversationRead('chat-1', older);

      check(
        container.read(conversationsProvider).requireValue.single.lastReadAt,
      ).equals(newer);
    });

    test('free markConversationRead ignores temporary chats', () {
      final socket = _RecordingSocketService();
      final container = makeContainer(
        extraOverrides: [socketServiceProvider.overrideWithValue(socket)],
      );

      markConversationRead(container, 'local:socket-id');

      check(socket.emits).isEmpty();
    });

    test(
      'free markConversationRead emits the events:chat socket frame',
      () async {
        await seedServerChat('chat-1', updatedAt: 100);
        final socket = _RecordingSocketService();
        final container = makeContainer(
          extraOverrides: [socketServiceProvider.overrideWithValue(socket)],
        );
        await container.read(conversationsProvider.future);

        markConversationRead(container, 'chat-1');

        check(socket.emits.length).equals(1);
        check(socket.emits.single.$1).equals('events:chat');
        check(
          (socket.emits.single.$2 as Map<String, dynamic>)['chat_id'],
        ).equals('chat-1');
      },
    );

    test('upsertConversation writes an envelope stub the next emission agrees '
        'with', () async {
      final container = makeContainer();
      await container.read(conversationsProvider.future);

      container
          .read(conversationsProvider.notifier)
          .upsertConversation(_conversation('chat-new', updatedAtSeconds: 300));

      // Synchronous in-memory upsert.
      check(
        idsOf(container.read(conversationsProvider).requireValue),
      ).deepEquals(['chat-new']);

      // The stub row materializes and the stream emission keeps the chat
      // (no flicker revert — risk guard 6).
      final row = await waitForAsync<ChatRow?>(
        () => db.chatsDao.getChat('chat-new'),
        condition: (row) => row != null,
      );
      check(row!.bodySynced).isFalse();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      check(
        idsOf(container.read(conversationsProvider).requireValue),
      ).deepEquals(['chat-new']);
    });

    test('updateConversation persists the rename across emissions', () async {
      await seedServerChat('chat-1', updatedAt: 100);
      final container = makeContainer();
      await container.read(conversationsProvider.future);

      container
          .read(conversationsProvider.notifier)
          .updateConversation(
            'chat-1',
            (conversation) => conversation.copyWith(
              title: 'Renamed',
              updatedAt: DateTime.fromMillisecondsSinceEpoch(200 * 1000),
            ),
          );

      check(
        container.read(conversationsProvider).requireValue.single.title,
      ).equals('Renamed');

      await waitForAsync<ChatRow?>(
        () => db.chatsDao.getChat('chat-1'),
        condition: (row) => row?.title == 'Renamed',
      );
      // The next emission agrees with the optimistic state.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      check(
        container.read(conversationsProvider).requireValue.single.title,
      ).equals('Renamed');
    });

    test(
      'updateConversationFromRemote keeps the frozen signature working',
      () async {
        await seedServerChat('chat-1', updatedAt: 100);
        final container = makeContainer();
        await container.read(conversationsProvider.future);

        container
            .read(conversationsProvider.notifier)
            .updateConversationFromRemote(
              'chat-1',
              (conversation) => conversation.copyWith(title: 'Remote rename'),
            );

        check(
          container.read(conversationsProvider).requireValue.single.title,
        ).equals('Remote rename');
      },
    );

    test(
      'missing remote conversation update submits reconcile pull immediately',
      () async {
        final pulls = <String>[];
        final container = makeContainer(
          extraOverrides: [
            syncEngineProvider.overrideWith(() => _RecordingSyncEngine(pulls)),
          ],
        );
        await container.read(conversationsProvider.future);

        container
            .read(conversationsProvider.notifier)
            .updateConversationFromRemote(
              'missing-chat',
              (_) => throw StateError('unexpected transform'),
            );

        check(pulls).deepEquals(['conversations-reconcile']);
      },
    );

    test('removeConversation hard-deletes the local row', () async {
      await seedServerChat('chat-1', updatedAt: 100);
      await seedServerChat('chat-2', updatedAt: 200);
      final container = makeContainer();
      await container.read(conversationsProvider.future);

      container
          .read(conversationsProvider.notifier)
          .removeConversation('chat-1');

      check(
        idsOf(container.read(conversationsProvider).requireValue),
      ).deepEquals(['chat-2']);

      await waitForAsync<ChatRow?>(
        () => db.chatsDao.getChat('chat-1'),
        condition: (row) => row == null,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      check(
        idsOf(container.read(conversationsProvider).requireValue),
      ).deepEquals(['chat-2']);
    });

    test(
      'trustConversation is a no-op and loadMore reports no pagination',
      () async {
        await seedServerChat('chat-1', updatedAt: 100);
        final container = makeContainer();
        final before = await container.read(conversationsProvider.future);

        final notifier = container.read(conversationsProvider.notifier);
        notifier.trustConversation('chat-1');
        await notifier.loadMore();

        check(
          container.read(conversationsProvider).requireValue,
        ).deepEquals(before);
        check(notifier.hasMoreRegularChats()).isFalse();
        check(notifier.isLoadingMoreRegularChats()).isFalse();
      },
    );

    test('refresh delegates to the sync engine pull', () async {
      final server = FakeOpenWebUiServer();
      final client = FakeSyncApiClient(server);
      server.seedChat(
        id: 'remote-chat',
        blob: {
          'title': 'Remote chat',
          'history': {
            'messages': {
              'm1': {
                'id': 'm1',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'hi',
                'timestamp': 100,
              },
            },
            'currentId': 'm1',
          },
        },
        createdAt: 100,
        updatedAt: 100,
      );
      final container = makeContainer(
        extraOverrides: [syncApiClientProvider.overrideWith((ref) => client)],
      );
      await container.read(conversationsProvider.future);

      await container
          .read(conversationsProvider.notifier)
          .refresh(forceFresh: true);

      check(client.chatListPageRequests).isGreaterOrEqual(1);
      await waitFor(() {
        final state = container.read(conversationsProvider);
        return idsOf(state.asData?.value ?? const []).contains('remote-chat');
      });
    });
  });

  group('folderConversationSummariesProvider', () {
    test('reads folder membership from the database', () async {
      await seedServerChat('chat-in-folder', updatedAt: 200, folderId: 'f1');
      await seedServerChat('chat-root', updatedAt: 300);
      final container = makeContainer();

      final summaries = await container.read(
        folderConversationSummariesProvider('f1').future,
      );

      check(idsOf(summaries)).deepEquals(['chat-in-folder']);
      check(summaries.single.folderId).equals('f1');
    });

    test('returns empty when unauthenticated', () async {
      await seedServerChat('chat-in-folder', updatedAt: 200, folderId: 'f1');
      final container = makeContainer(authenticated: false);

      final summaries = await container.read(
        folderConversationSummariesProvider('f1').future,
      );

      check(summaries).isEmpty();
    });

    test('refreshConversationsCache bumps the refresh tick', () async {
      await seedServerChat('chat-a', updatedAt: 200, folderId: 'f1');
      final container = makeContainer();
      final before = await container.read(
        folderConversationSummariesProvider('f1').future,
      );
      check(idsOf(before)).deepEquals(['chat-a']);

      await seedServerChat('chat-b', updatedAt: 300, folderId: 'f1');
      refreshConversationsCache(container);

      await waitFor(() {
        final state = container.read(folderConversationSummariesProvider('f1'));
        return idsOf(state.asData?.value ?? const []).contains('chat-b');
      });
      final after = await container.read(
        folderConversationSummariesProvider('f1').future,
      );
      check(idsOf(after)).deepEquals(['chat-b', 'chat-a']);
    });
  });
}

Conversation _conversation(
  String id, {
  int updatedAtSeconds = 100,
  DateTime? lastReadAt,
}) {
  return Conversation(
    id: id,
    title: 'Title $id',
    createdAt: DateTime.fromMillisecondsSinceEpoch(updatedAtSeconds * 1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtSeconds * 1000),
    lastReadAt: lastReadAt,
  );
}

class _RecordingSocketService extends SocketService {
  _RecordingSocketService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test-server',
          name: 'Test Server',
          url: 'https://example.com',
        ),
      );

  final List<(String, dynamic)> emits = <(String, dynamic)>[];

  @override
  void emit(String event, dynamic data) {
    emits.add((event, data));
  }
}
