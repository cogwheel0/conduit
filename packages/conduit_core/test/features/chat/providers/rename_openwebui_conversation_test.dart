import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/auth/api_auth_interceptor.dart'
    show ApiAuthSnapshot;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_manager.dart';
import 'package:conduit_core/database/database_provider.dart';
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
import 'package:conduit_core/sync/deletion_reconcile.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/push_sync.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
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

  /// Holds the model's title, once asked for.
  Completer<void>? titleGate;
  final Completer<void> titleAsked = Completer<void>();

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
  }) async {
    if (!titleAsked.isCompleted) titleAsked.complete();
    await titleGate?.future;
    return generatedTitle;
  }

  /// The title the model writes.
  String generatedTitle = _renamed;
}

/// The signed-in account's database, which a sign-in elsewhere replaces.
final class _SignedInDatabase extends Notifier<AppDatabase> {
  _SignedInDatabase(this.initial);

  final AppDatabase initial;

  @override
  AppDatabase build() => initial;

  void set(AppDatabase database) => state = database;
}

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

final class _SignedInApi extends Notifier<ApiService?> {
  _SignedInApi(this.initial);

  final ApiService initial;

  @override
  ApiService? build() => initial;

  void signInElsewhere() => state = _ServerApi(FakeOpenWebUiServer());
}

final class _NoModels extends Models {
  @override
  Future<List<Model>> build() async => const [];
}

final class _NoConversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const [];
}

/// Holds a read of a chat, of the chat list or of the archived list once
/// the server has answered it.
final class _HeldReadClient extends FakeSyncApiClient {
  _HeldReadClient(super.server);

  Future<void>? readGate;
  Completer<void> read = Completer<void>();
  Future<void>? listGate;
  Future<void>? archivedListGate;
  Completer<void> listRead = Completer<void>();

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    final answer = await super.getChatRaw(id);
    if (!read.isCompleted) read.complete();
    await readGate;
    return answer;
  }

  @override
  Future<List<Map<String, dynamic>>> getChatListPage(int page) =>
      _held(super.getChatListPage(page), listGate);

  @override
  Future<List<Map<String, dynamic>>> getArchivedChatListPage(int page) =>
      _held(super.getArchivedChatListPage(page), archivedListGate);

  Future<List<Map<String, dynamic>>> _held(
    Future<List<Map<String, dynamic>>> page,
    Future<void>? gate,
  ) async {
    final answer = await page;
    if (gate == null) return answer;
    if (!listRead.isCompleted) listRead.complete();
    await gate;
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

  /// Each way this device writes a chat's title: what it does, whether the
  /// account it was made in is still signed in after it, how it ends when
  /// that account's chats are closing before it starts, and the longest
  /// request it waits on, held.
  final titleWrites =
      <
        ({
          String name,
          Future<bool> Function(ProviderContainer) write,
          Matcher refused,
          ({void Function() release, Future<void> reached}) Function(_ServerApi)
          hold,
        })
      >[
        (
          name: 'a rename',
          write: (c) => renameOpenWebUiConversation(c, _chatId, _renamed),
          refused: throwsA(isA<OpenWebUiAccountChangedException>()),
          hold: (api) {
            final gate = api.gate = Completer<void>();
            return (release: gate.complete, reached: api.asked.future);
          },
        ),
        (
          name: 'a generated title',
          write: (c) async => (await generateConversationTitle(
            c,
            _chatId,
            selectedModelId: 'llama3',
          )).current,
          refused: completion(isFalse),
          hold: (api) {
            final gate = api.titleGate = Completer<void>();
            return (release: gate.complete, reached: api.titleAsked.future);
          },
        ),
      ];
  for (final (:name, :write, refused: _, hold: _) in titleWrites) {
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

  test('an archived chat listed before the rename does not get the old title '
      'back, and the rest of the list applies', () async {
    const archivedId = 'chat-archived';
    const otherId = 'chat-archived-elsewhere';
    for (final (id, title) in [
      (archivedId, _title),
      (otherId, 'Renamed elsewhere'),
    ]) {
      server.seedChat(
        id: id,
        blob: {'title': title},
        createdAt: 100,
        updatedAt: 100,
        archived: true,
      );
      await db.chatsDao.upsertEnvelopeStub(
        id: id,
        title: _title,
        createdAt: 100,
        updatedAt: 100,
        archived: true,
      );
    }
    final released = Completer<void>();
    client.archivedListGate = released.future;
    final pulling = pull.run();
    await client.listRead.future;

    await renameOpenWebUiConversation(container, archivedId, _renamed);
    released.complete();
    await pulling;

    expect((await db.chatsDao.getChat(archivedId))!.title, _renamed);
    expect((await db.chatsDao.getChat(otherId))!.title, 'Renamed elsewhere');
  });

  test(
    'the full list read before the rename does not put the old title '
    'back, nor does the next save, and the rest of the list applies',
    () async {
      const otherId = 'chat-elsewhere';
      server.seedChat(
        id: otherId,
        blob: {'title': _title},
        createdAt: 100,
        updatedAt: 100,
      );
      await pull.pullChat(otherId);
      server.updateChat(otherId, {'title': 'Renamed elsewhere'});
      final released = Completer<void>();
      client.listGate = released.future;
      final reconciling = DeletionReconcile(
        client: client,
        db: db,
        locks: locks,
        clock: _Clock(),
      ).run(ReconcileReason.manualRefresh);
      await client.listRead.future;

      await renameOpenWebUiConversation(container, _chatId, _renamed);
      released.complete();
      await reconciling;

      expect((await db.chatsDao.getChat(otherId))!.title, 'Renamed elsewhere');
      expect(await storedTitle(), _renamed);
      expect(await storedServerTitle(), _renamed);
      await queueSave();
      await drainer.drain();
      expect(serverTitle(), _renamed);
    },
  );

  test('a copy of the chat read before the rename and shown in the chat list '
      'does not put the old title back', () async {
    final chats = container.read(conversationsProvider.notifier);
    await container.read(conversationsProvider.future);
    final readBefore = Conversation(
      id: _chatId,
      title: _title,
      createdAt: DateTime.utc(2026, 11, 1),
      updatedAt: DateTime.utc(2026, 11, 1),
    );
    Future<void> written() => locks.runExclusive(_chatId, () async {});

    await renameOpenWebUiConversation(container, _chatId, _renamed);
    chats.upsertConversation(readBefore);
    await written();
    expect(await storedTitle(), _renamed);

    chats.updateConversation(_chatId, (_) => readBefore);
    await written();
    expect(await storedTitle(), _renamed);
  });

  test('a save of the chat on its way when it is renamed lands first, and '
      'the rename stays', () async {
    await queueSave();
    final held = Completer<void>();
    final sent = Completer<void>();
    client
      ..updateChatGate = held.future
      ..onUpdateChat = (_, _) => sent.complete();
    final draining = drainer.drain();
    await sent.future;

    final renaming = renameOpenWebUiConversation(container, _chatId, _renamed);
    held.complete();
    await draining;
    await renaming;

    expect(serverTitle(), _renamed);
    expect(await storedTitle(), _renamed);
  });

  test('a save queued when the chat is renamed sends the new title, which '
      'shows at once', () async {
    await queueSave();

    await renameOpenWebUiConversation(container, _chatId, _renamed);
    expect(await storedTitle(), _renamed);

    await drainer.drain();
    await pull.pullChat(_chatId);
    expect(serverTitle(), _renamed);
    expect(await storedTitle(), _renamed);
  });

  test('a rename that waited for a generated title is the title stored, '
      'shown, and sent by the next save', () async {
    const generated = 'Made by the model';
    api
      ..generatedTitle = generated
      ..gate = Completer<void>();
    final chats = container.read(conversationsProvider.notifier);
    await container.read(conversationsProvider.future);
    chats.upsertConversation(
      Conversation(
        id: _chatId,
        title: _title,
        createdAt: DateTime.utc(2026, 11, 1),
        updatedAt: DateTime.utc(2026, 11, 1),
      ),
    );
    final generating = generateConversationTitle(
      container,
      _chatId,
      selectedModelId: 'llama3',
    );
    await api.asked.future;
    // Behind the title generation's locks, which hold for its server write.
    final renaming = renameOpenWebUiConversation(container, _chatId, _renamed);
    api.gate!.complete();
    await generating;
    await renaming;
    await locks.runExclusive(_chatId, () async {});

    expect(serverTitle(), _renamed);
    expect(await storedTitle(), _renamed);
    expect(await storedServerTitle(), _renamed);
    expect(
      container.read(conversationsProvider).requireValue.single.title,
      _renamed,
    );
    await queueSave();
    await drainer.drain();
    expect(serverTitle(), _renamed);
  });

  test('a title event received while a rename waits for the chat does not '
      'replace the rename, stored or shown', () async {
    final chats = container.read(conversationsProvider.notifier);
    await container.read(conversationsProvider.future);
    chats.upsertConversation(
      Conversation(
        id: _chatId,
        title: _title,
        createdAt: DateTime.utc(2026, 11, 1),
        updatedAt: DateTime.utc(2026, 11, 1),
      ),
    );
    final saving = Completer<void>();
    final save = locks.runExclusive(_chatId, () => saving.future);
    final renaming = renameOpenWebUiConversation(container, _chatId, _renamed);
    await pumpEventQueue();

    chats.applyServerGeneratedTitle(_chatId, 'Made by the server');
    saving.complete();
    await save;
    await renaming;
    await locks.runExclusive(_chatId, () async {});

    expect(await storedTitle(), _renamed);
    expect(await storedServerTitle(), _renamed);
    expect(
      container.read(conversationsProvider).requireValue.single.title,
      _renamed,
    );
    await queueSave();
    await drainer.drain();
    expect(serverTitle(), _renamed);
  });

  test('a rename the server refuses leaves the chat its title', () async {
    api.failure = Exception('refused');

    await expectLater(
      renameOpenWebUiConversation(container, _chatId, _renamed),
      throwsException,
    );
    expect(await storedTitle(), _title);
    expect(serverTitle(), _title);
  });

  group('in the database of the account the title was written in', () {
    late bool warnedOfReopening;
    late Directory folder;
    late DatabaseManager databases;
    late NotifierProvider<_SignedInApi, ApiService?> signedInApi;
    late NotifierProvider<_SignedInDatabase, AppDatabase> signedInDatabase;
    late ProviderContainer signedIn;

    // The account's database is opened again once it has closed.
    setUpAll(() {
      warnedOfReopening = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    });

    tearDownAll(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = warnedOfReopening;
    });

    setUp(() async {
      folder = Directory.systemTemp.createTempSync('conduit_rename');
      databases = DatabaseManager(
        databaseDirectory: () async => folder,
        openDatabase: (name) =>
            AppDatabase(NativeDatabase(File('${folder.path}/$name.sqlite'))),
      );
      final accountA = databases.openForServerId('account-a');
      await PullSync(
        client: FakeSyncApiClient(server),
        db: accountA,
        locks: ConversationLocks(),
      ).pullChat(_chatId);
      signedInApi = NotifierProvider<_SignedInApi, ApiService?>(
        () => _SignedInApi(api),
      );
      signedInDatabase = NotifierProvider<_SignedInDatabase, AppDatabase>(
        () => _SignedInDatabase(accountA),
      );
      signedIn = ProviderContainer(
        overrides: [
          openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
          appDatabaseProvider.overrideWith(
            (ref) => ref.watch(signedInDatabase),
          ),
          databaseManagerProvider.overrideWithValue(databases),
          apiServiceProvider.overrideWith((ref) => ref.watch(signedInApi)),
          openWebUiAuthSessionEpochProvider.overrideWithValue(Object()),
        ],
      );
    });

    tearDown(() async {
      signedIn.dispose();
      await databases.closeAll();
      folder.deleteSync(recursive: true);
    });

    for (final (:name, :write, :refused, :hold) in titleWrites) {
      test(
        '$name the server took as another server\'s account was signed '
        'in to is stored with the chats it was made in, and succeeds',
        () async {
          final held = hold(api);
          final writing = write(signedIn);
          await held.reached;
          final accountB = databases.openForServerId('account-b');
          signedIn.read(signedInApi.notifier).signInElsewhere();
          signedIn.read(signedInDatabase.notifier).set(accountB);
          await pumpEventQueue();
          held.release();

          expect(await writing, isFalse);
          expect(serverTitle(), _renamed);
          // Nothing of it in the other account's chats, which can hold
          // another chat under the same id.
          expect(await accountB.chatsDao.getChat(_chatId), isNull);
          expect(accountB.chatsDao.titleWrittenSince(_chatId, 0), isFalse);
          if (databases.openForServerIdIfReady('account-a')
              case DatabaseOpenDeferred(:final retryAfter)) {
            await retryAfter;
          }
          final accountA = databases.openForServerId('account-a');
          expect((await accountA.chatsDao.getChat(_chatId))!.title, _renamed);
        },
      );

      test('$name asked for once another server\'s account was signed in to '
          'is not sent', () async {
        databases.openForServerId('account-b');

        await expectLater(write(signedIn), refused);
        expect(api.asked.isCompleted, isFalse);
        expect(api.titleAsked.isCompleted, isFalse);
        expect(serverTitle(), _title);
      });
    }
  });
}
