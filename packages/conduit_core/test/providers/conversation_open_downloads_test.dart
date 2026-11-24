import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart'
    show MessageRowData;
import 'package:conduit_core/database/local_conversation_loader.dart'
    show kOpenRefreshDirectPullMaxPayloadLength, readStoredConversation;
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
import 'package:dio/dio.dart';
import 'package:drift/drift.dart'
    show
        ApplyInterceptor,
        QueryExecutor,
        QueryInterceptor,
        Value,
        driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// Completes [armed] once a read of the messages table, made after it was
/// set, has returned its rows.
final class _MessageReadSignal extends QueryInterceptor {
  Completer<void>? armed;

  static final RegExp _fromMessages = RegExp(r'FROM\s+"?messages"?\b');

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(statement, args);
    final waiting = armed;
    if (waiting != null && _fromMessages.hasMatch(statement)) {
      armed = null;
      waiting.complete();
    }
    return rows;
  }
}

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
/// Over [wire], a fetch goes through the service's own HTTP client.
final class _CountingApi extends ApiService {
  _CountingApi({this.wire})
    : super(
        serverConfig: const ServerConfig(
          id: 'server-a',
          name: 'server-a',
          url: 'https://server-a.example.test',
        ),
        workerManager: WorkerManager(),
      );

  final _BearerRecorder? wire;
  int getConversationCalls = 0;

  @override
  Future<Conversation> getConversation(
    String id, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    getConversationCalls++;
    if (wire case final wire?) {
      dio.httpClientAdapter = wire;
      return super.getConversation(id, authSnapshot: authSnapshot);
    }
    return Conversation(
      id: id,
      title: 'Direct fetch',
      createdAt: DateTime.utc(2026, 10, 9),
      updatedAt: DateTime.utc(2026, 10, 9),
    );
  }
}

/// Answers every request with an empty chat, keeping the bearer each came
/// with.
final class _BearerRecorder implements HttpClientAdapter {
  final bearers = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    bearers.add(options.headers['Authorization'] as String?);
    return ResponseBody.fromString(
      jsonEncode({'id': 'chat-1', 'title': 'Direct fetch', 'chat': {}}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Runs [onRead] once, as the next read of the outbox returns.
final class _OutboxReadTap extends QueryInterceptor {
  void Function()? onRead;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await executor.runSelect(statement, args);
    final read = onRead;
    if (read != null && statement.contains('FROM "outbox_ops"')) {
      onRead = null;
      read();
    }
    return rows;
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

    test('a direct fetch is made only as the account that opened it', () async {
      final reads = _OutboxReadTap();
      await db.close();
      db = AppDatabase(NativeDatabase.memory().interceptWith(reads));
      final wire = _BearerRecorder();
      api = _CountingApi(wire: wire)..updateAuthToken('account-a');
      final container = open(useSyncClient: false);
      // The token is replaced, before the app's session says so, while the
      // deletes still to land are read.
      reads.onRead = () => api.updateAuthToken('account-b');

      final failure = await container
          .read(loadConversationProvider('chat-1').future)
          .then<Object?>((_) => null, onError: (Object error) => error);

      check(reads.onRead).isNull();
      check(wire.bearers).isEmpty();
      check(failure).isA<OpenWebUiConversationOwnershipException>();
    });
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

    /// A chat whose Direct answer the server holds as still being written,
    /// as a host that quit or died mid-reply left it.
    Future<void> storeWriting(String id, {int updatedAt = 150}) async {
      server.seedChat(
        id: id,
        blob: <String, dynamic>{
          'title': 'Title $id',
          'models': ['llama3'],
          'history': {
            'messages': {
              '$id-q': {
                'id': '$id-q',
                'parentId': null,
                'childrenIds': ['$id-a'],
                'role': 'user',
                'content': 'Which shelf?',
                'timestamp': 100,
              },
              '$id-a': {
                'id': '$id-a',
                'parentId': '$id-q',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': 'The top',
                'timestamp': 101,
                'done': false,
                'isStreaming': true,
                'metadata': {'transport': 'direct'},
              },
            },
            'currentId': '$id-a',
          },
        },
        createdAt: 100,
        updatedAt: updatedAt,
      );
      final stored = await PullSync(
        client: FakeSyncApiClient(server),
        db: db,
        locks: ConversationLocks(),
      ).pullChat(id);
      check(stored).isNotNull();
    }

    test('a Direct answer no run here writes opens finished, without moving '
        'the chat or queueing a push to the server', () async {
      await storeWriting('writing');
      final before = (await db.chatsDao.getChat('writing'))!;
      final container = openRecording();

      final loaded = await container.read(
        loadConversationProvider('writing').future,
      );

      final answer = loaded.messages.last;
      check(answer.content).equals('The top');
      check(answer.isStreaming).isFalse();
      final stored = await db.messagesDao.getMessage('writing', 'writing-a');
      check(
        (jsonDecode(stored!.payload) as Map)['isStreaming'],
      ).equals(false);
      final after = (await db.chatsDao.getChat('writing'))!;
      check(after.updatedAt).equals(before.updatedAt);
      check(after.dirty).equals(before.dirty);
      check(await db.outboxDao.activeForChat('writing')).isEmpty();
    });

    test('a stuck Direct answer whose newer words are owed to the server '
        'keeps them, and the push that owes them, through a pull of the '
        'server\'s older copy', () async {
      await storeWriting('owed');
      final row = (await db.messagesDao.getMessage('owed', 'owed-a'))!;
      // A checkpoint stored here and not yet pushed, as an approval stores
      // one before the app quits: newer words, the row dirty, an update owed.
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: 'owed',
        messages: <MessageRowData>[
          MessageRowData(
            id: row.id,
            chatId: 'owed',
            parentId: row.parentId,
            role: row.role,
            content: 'The top one, by the',
            model: row.model,
            createdAt: row.createdAt,
            orderIndex: row.orderIndex,
            payload: <String, dynamic>{
              ...jsonDecode(row.payload) as Map<String, dynamic>,
              'content': 'The top one, by the',
              'isStreaming': true,
            },
          ),
        ],
        enqueueCompletion: false,
      );
      final container = openRecording();

      final loaded = await container.read(
        loadConversationProvider('owed').future,
      );
      check(loaded.messages.last.content).equals('The top one, by the');
      check(loaded.messages.last.isStreaming).isFalse();
      check(
        (await db.messagesDao.getMessage('owed', 'owed-a'))!.dirty,
      ).isTrue();

      // The server's copy changes again, its answer the older checkpoint.
      await storeWriting('owed', updatedAt: 160);
      final stored = (await db.messagesDao.getMessage('owed', 'owed-a'))!;
      check(stored.content).equals('The top one, by the');
      check(
        (jsonDecode(stored.payload) as Map)['isStreaming'],
      ).equals(false);
      check(await db.outboxDao.activeForChat('owed')).isNotEmpty();
    });

    test('a Direct answer a run finishes while the chat opens opens as that '
        'run stored it', () async {
      await db.close();
      final reads = _MessageReadSignal();
      db = AppDatabase(NativeDatabase.memory().interceptWith(reads));
      await storeWriting('racing');
      final container = openRecording();
      // The run holds the chat's lock, as runs do while they write.
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final held = container
          .read(chatLocksProvider)
          .runExclusive('racing', () => release.future);

      final snapshotRead = Completer<void>();
      reads.armed = snapshotRead;
      final loading = container.read(
        loadConversationProvider('racing').future,
      );
      // The open has read the answer as still being written; the settle
      // then waits on the lock.
      await snapshotRead.future;
      // The run's own last write, under the chat's lock as runs take it.
      final row = (await db.messagesDao.getMessage('racing', 'racing-a'))!;
      await (db.update(db.messages)..where((t) => t.id.equals('racing-a')))
          .write(
            MessagesCompanion(
              content: const Value('The top one.'),
              payload: Value(
                jsonEncode(<String, dynamic>{
                  ...jsonDecode(row.payload) as Map<String, dynamic>,
                  'content': 'The top one.',
                  'isStreaming': false,
                  'done': true,
                }),
              ),
            ),
          );
      release.complete();
      await held;

      final answer = (await loading).messages.last;
      check(answer.content).equals('The top one.');
      check(answer.isStreaming).isFalse();
    });

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

  group('reading a chat\'s stored copy', () {
    late List<String> pulls;
    late List<String> cycles;

    setUp(() {
      pulls = <String>[];
      cycles = <String>[];
    });

    ProviderContainer openRecording() =>
        open(engine: () => _RecordingSyncEngine(pulls, cycles));

    test('reads a stored chat with no refresh and no download', () async {
      await store('small');
      final container = openRecording();

      final stored = await readStoredConversation(container, 'small');

      check(stored!.messages.single.content).equals('hello');
      check(chatStorageKindOf(stored)).equals(ChatStorageKind.openWebUi);
      check(pulls).isEmpty();
      check(cycles).isEmpty();
      check(client.chatFetchStarts).isEmpty();
      check(api.getConversationCalls).equals(0);
    });

    test('finds nothing for a chat with no stored body, and asks the server '
        'for nothing', () async {
      server.seedChat(
        id: 'chat-1',
        blob: _blob('chat-1'),
        createdAt: 100,
        updatedAt: 150,
      );
      final container = openRecording();

      check(await readStoredConversation(container, 'chat-1')).isNull();
      check(pulls).isEmpty();
      check(client.chatFetchStarts).isEmpty();
      check(api.getConversationCalls).equals(0);
    });
  });

  group('reopening a large stored chat with the real sync engine', () {
    final large = 'x' * (kOpenRefreshDirectPullMaxPayloadLength + 1);

    Future<void> waitFor(FutureOr<bool> Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await condition()) {
        if (DateTime.now().isAfter(deadline)) fail('waitFor timed out');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    // Waits for the cycle the open started: a list read after the open, then
    // the engine idle again. Requesting a cycle here would start one itself.
    Future<void> openCycleFinished(
      ProviderContainer container,
      int listReads,
    ) => waitFor(
      () =>
          client.chatListPageRequests > listReads &&
          container.read(syncEngineProvider).phase == SyncPhase.idle,
    );

    test('an edit made on the server reaches the open chat', () async {
      server.seedChat(
        id: 'large',
        blob: _blob('large', content: large),
        createdAt: 100,
        updatedAt: 150,
      );
      final container = open();
      final engine = container.read(syncEngineProvider.notifier);
      check((await engine.requestPull(reason: 'initial'))?.success)
          .equals(true);
      server.seedChat(
        id: 'large',
        blob: _blob('large', content: '${large}edited'),
        createdAt: 100,
        updatedAt: 300,
      );
      final listReads = client.chatListPageRequests;
      client.chatFetchStarts.clear();

      final opened = await container.read(
        loadConversationProvider('large').future,
      );
      await openCycleFinished(container, listReads);

      check(opened.messages.single.content).equals(large);
      final stored = await db.messagesDao.getForChat('large');
      check(stored.single.content).equals('${large}edited');
      check(client.chatFetchStarts).deepEquals(['large']);
    });

    test('an unchanged chat is not downloaded again', () async {
      server.seedChat(
        id: 'large',
        blob: _blob('large', content: large),
        createdAt: 100,
        updatedAt: 100,
      );
      // A newer chat moves the watermark past the overlap window, so the
      // cycle has no reason to re-read the large one.
      server.seedChat(
        id: 'newer',
        blob: _blob('newer'),
        createdAt: 200,
        updatedAt: 200,
      );
      final container = open();
      final engine = container.read(syncEngineProvider.notifier);
      check((await engine.requestPull(reason: 'initial'))?.success)
          .equals(true);
      final listReads = client.chatListPageRequests;
      client.chatFetchStarts.clear();

      final opened = await container.read(
        loadConversationProvider('large').future,
      );
      await openCycleFinished(container, listReads);

      check(opened.messages.single.content).equals(large);
      check(client.chatFetchStarts).not((it) => it.contains('large'));
    });
  });
}
