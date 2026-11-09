import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_transport.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_sync_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/worker_port.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/primary_sync_provider.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _root = '00000000-0000-0000-0000-000000000000';

final class _Preferred extends PreferredBackendController {
  _Preferred(this.value);

  PreferredBackend value;

  @override
  PreferredBackend build() => value;

  void choose(PreferredBackend backend) => state = value = backend;
}

/// Which LibreChat account's database is open: the test's own, or another.
final class _OtherAccount extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}

final _otherAccountProvider = NotifierProvider<_OtherAccount, bool>(
  _OtherAccount.new,
);

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _IdleSyncEngine extends SyncEngine {
  final List<String> pulls = <String>[];

  @override
  Future<PullResult?> requestPull({required String reason}) {
    pulls.add(reason);
    return Future<PullResult?>.value(null);
  }
}

/// Runs jobs inline, counting them: each one would leave the UI isolate.
final class _CountingWorkerPort implements WorkerPort {
  int runs = 0;

  @override
  Future<R> run<Q, R>(WorkerCallback<Q, R> callback, Q message) {
    runs++;
    return Future<R>.sync(() => callback(message));
  }
}

List<Map<String, dynamic>> _turn(String id) => [
  {
    'messageId': '$id-q',
    'parentMessageId': _root,
    'isCreatedByUser': true,
    'text': 'Question $id',
    'createdAt': '2026-10-18T10:00:00.000Z',
  },
  {
    'messageId': '$id-a',
    'parentMessageId': '$id-q',
    'isCreatedByUser': false,
    'text': 'Answer $id',
    'content': [
      {'type': 'text', 'text': 'Answer $id'},
    ],
    'createdAt': '2026-10-18T10:00:05.000Z',
  },
];

ChatRows _owuiRows(String id) => ChatBlobMapper.blobToRows(
  chatId: id,
  blob: {
    'title': 'Open WebUI chat',
    'history': {
      'messages': {
        'm1': {
          'id': 'm1',
          'parentId': null,
          'childrenIds': <String>[],
          'role': 'user',
          'content': 'from open webui',
          'timestamp': 1,
        },
      },
      'currentId': 'm1',
    },
  },
  title: 'Open WebUI chat',
  createdAt: 1,
  updatedAt: 1,
);

/// Waits out the quiet spell after which a search reruns on chat writes.
Future<void> _searchSettled() async {
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await pumpEventQueue();
}

void main() {
  const server = LibreChatServer(baseUrl: 'https://chat.example.com');
  late FakeLibreChatServer fake;
  late AppDatabase libreChatDb;
  late AppDatabase otherAccountDb;
  late AppDatabase owuiDb;
  late AppDatabase directDb;
  late ProviderContainer container;
  late _Preferred preferred;
  late _IdleSyncEngine owuiSync;
  late _CountingWorkerPort workerPort;
  late WorkerManager workers;
  // The real date: sessions the fake server issues are checked against the
  // real clock, and would lapse against a fixed one.
  final now = DateTime.now().toUtc();

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    fake = FakeLibreChatServer(clock: () => now)..addUser();
    libreChatDb = AppDatabase(NativeDatabase.memory());
    otherAccountDb = AppDatabase(NativeDatabase.memory());
    owuiDb = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
    await owuiDb.chatsDao.upsertServerChat(rows: _owuiRows('owui-chat'));
    workers = WorkerManager(worker: workerPort = _CountingWorkerPort());

    container = ProviderContainer(
      // A failed load is not retried: a retry would be a new load, under
      // whichever account then owns the tab.
      retry: (_, _) => null,
      overrides: [
        // Open WebUI's store is open and populated, as at the moment a
        // switch completes: it must still never be consulted.
        ...openWebUiStorageOpenOverrides(database: owuiDb),
        preferredBackendProvider.overrideWith(
          () => preferred = _Preferred(PreferredBackend.libreChat),
        ),
        secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
        libreChatHttpAdapterProvider.overrideWithValue(fake),
        libreChatDatabaseProvider.overrideWith((ref) {
          final session = ref.watch(libreChatSessionProvider).asData?.value;
          if (session is! LibreChatSignedInState) return null;
          return ref.watch(_otherAccountProvider) ? otherAccountDb : libreChatDb;
        }),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        workerManagerProvider.overrideWithValue(workers),
        isOnlineProvider.overrideWithValue(true),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(null),
        apiServiceProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(() => owuiSync = _IdleSyncEngine()),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
      ],
    );

    final auth = LibreChatAuthService(server, adapter: fake);
    final signedIn =
        await auth.signIn(email: 'dev@example.com', password: 'devpassword')
            as LibreChatSignedIn;
    auth.close();
    await container
        .read(libreChatAccountsProvider)
        .saveSignedIn(server: server, session: signedIn.session);
    await container.read(libreChatSessionProvider.future);

    fake
      ..addConversation(
        'lc-1',
        title: 'Paris weather',
        updatedAt: now,
        messageList: _turn('lc-1'),
      )
      ..addConversation(
        'lc-2',
        title: 'Recipes',
        updatedAt: now.subtract(const Duration(hours: 1)),
        messageList: _turn('lc-2'),
      );
  });

  tearDown(() async {
    container.dispose();
    workers.dispose();
    await libreChatDb.close();
    await otherAccountDb.close();
    await owuiDb.close();
    await directDb.close();
    PreferencesStore.debugReset();
  });

  Future<void> pull() async {
    final result = await container
        .read(primarySyncProvider)
        .requestPull(reason: 'test');
    check(result?.success).equals(true);
  }

  Future<List<Conversation>> listed() async {
    // The list follows the database stream; let it settle.
    container.invalidate(conversationsProvider);
    return container.read(conversationsProvider.future);
  }

  test('LibreChat owns the sync and the store while it is primary', () async {
    check(
      container.read(primarySyncProvider),
    ).isA<LibreChatPrimarySync>().has((it) => it.canSync, 'canSync').isTrue();
    final repository = container.read(chatDatabaseRepositoryProvider);
    check(repository.hasLibreChatDatabase).isTrue();
    check(repository.hasOpenWebUiDatabase).isFalse();

    preferred.choose(PreferredBackend.owui);
    check(container.read(primarySyncProvider)).identicalTo(owuiSync);
    final owuiRepository = container.read(chatDatabaseRepositoryProvider);
    check(owuiRepository.hasLibreChatDatabase).isFalse();
    check(owuiRepository.hasOpenWebUiDatabase).isTrue();
  });

  test('the Chats list shows LibreChat chats, not Open WebUI\'s', () async {
    await pull();
    final conversations = await listed();
    check(
      conversations.map((conversation) => conversation.id),
    ).deepEquals(['lc-1', 'lc-2']);
    check(conversations.every(isLibreChatConversation)).isTrue();
    // Open WebUI's store was never written or read for LibreChat.
    check(await owuiDb.chatsDao.getChat('lc-1')).isNull();

    final hits = await container
        .read(chatDatabaseRepositoryProvider)
        .searchMergedChats('Question');
    check(
      hits.map((hit) => hit.hit.chatId),
    ).unorderedEquals(['lc-1', 'lc-2']);
    check(hits.every((hit) => hit.storage == ChatStorageKind.libreChat))
        .isTrue();
  });

  test('opening a stored chat loads it with LibreChat provenance', () async {
    await pull();
    final scoped = const ChatStorageIdentity(
      rawId: 'lc-1',
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    final conversation = await container.read(
      loadConversationProvider(scoped).future,
    );
    check(conversation.messages.map((message) => message.content)).deepEquals([
      'Question lc-1',
      'Answer lc-1',
    ]);
    check(conversation.metadata['backend']).equals(kLibreChatTransport);
    check(
      conversation.messages.last.metadata?['transport'],
    ).equals(kLibreChatTransport);
    check(conversation.messages.first.metadata?['transport']).isNull();
  });

  test('opening a chat not stored yet pulls it from LibreChat', () async {
    final conversation = await container.read(
      loadConversationProvider('lc-2').future,
    );
    check(conversation.title).equals('Recipes');
    check(isLibreChatConversation(conversation)).isTrue();
    check((await libreChatDb.chatsDao.getChat('lc-2'))!.bodySynced).isTrue();
    check(
      fake.requests.map((request) => request.path),
    ).contains('/api/messages/lc-2');
  });

  test('a long chat not stored yet is read on a worker', () async {
    final messages = <Map<String, dynamic>>[];
    var parent = _root;
    for (var index = 0; index < 120; index++) {
      final id = 'long-$index';
      messages.add({
        'messageId': id,
        'parentMessageId': parent,
        'isCreatedByUser': index.isEven,
        'text': 'Line $index',
        'createdAt': now.add(Duration(seconds: index)).toIso8601String(),
      });
      parent = id;
    }
    fake.addConversation(
      'lc-long',
      title: 'Long chat',
      updatedAt: now,
      messageList: messages,
    );

    final conversation = await container
        .read(primarySyncProvider)
        .pullChatNow('lc-long');
    check(conversation!.messages).length.equals(120);
    check(isLibreChatConversation(conversation)).isTrue();
    check(workerPort.runs).equals(1);
  });

  test('rename, pin and archive change the chat and reach the server', () async {
    await pull();
    final scoped = const ChatStorageIdentity(
      rawId: 'lc-1',
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    await renameLibreChatConversation(container, scoped, 'Weather in Paris');
    await pinConversation(container, scoped, true);
    await archiveConversation(container, scoped, true);

    final row = (await libreChatDb.chatsDao.getChat('lc-1'))!;
    check(row.title).equals('Weather in Paris');
    check(row.pinned).isTrue();
    check(row.archived).isTrue();

    await container.read(libreChatSyncEngineProvider)!.drain();
    final serverCopy = fake.conversations['lc-1']!;
    check(serverCopy['title']).equals('Weather in Paris');
    check(serverCopy['pinned']).equals(true);
    check(serverCopy['isArchived']).equals(true);
    check((await libreChatDb.chatsDao.getChat('lc-1'))!.dirty).isFalse();
    // Open WebUI's API was never asked.
    check(owuiSync.pulls).isEmpty();
  });

  test('pinning the open chat keeps the messages it shows', () async {
    await pull();
    final scoped = const ChatStorageIdentity(
      rawId: 'lc-1',
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    final opened = await container.read(
      loadConversationProvider(scoped).future,
    );
    container.read(activeConversationProvider.notifier).set(opened);
    // Newer history arrived since it opened, and shows.
    final shown = [
      ...opened.messages,
      ChatMessage(
        id: 'later',
        role: 'assistant',
        content: 'Later',
        timestamp: DateTime.utc(2026, 10, 18),
      ),
    ];
    container.read(chatMessagesProvider.notifier).setMessages(shown);

    await pinConversation(container, scoped, true);

    check(
      container.read(activeConversationProvider)!.messages.map((m) => m.id),
    ).deepEquals(shown.map((m) => m.id));
  });

  test('a delete leaves the list and the server, never coming back', () async {
    await pull();
    final scoped = const ChatStorageIdentity(
      rawId: 'lc-2',
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    await deleteLibreChatConversation(container, scoped);
    check(
      (await listed()).map((conversation) => conversation.id),
    ).deepEquals(['lc-1']);

    await container.read(libreChatSyncEngineProvider)!.drain();
    check(fake.conversations.containsKey('lc-2')).isFalse();
    await pull();
    check(
      (await listed()).map((conversation) => conversation.id),
    ).deepEquals(['lc-1']);
  });

  test('edits that waited out an account switch leave the new account\'s '
      'chat alone', () async {
    await pull();
    final scoped = const ChatStorageIdentity(
      rawId: 'lc-1',
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    final gate = Completer<void>();
    unawaited(
      container
          .read(libreChatChatLocksProvider)
          .runExclusive('lc-1', () => gate.future),
    );
    final edits = Future.wait([
      renameLibreChatConversation(container, scoped, 'Renamed before'),
      deleteLibreChatConversation(container, scoped),
    ]);
    await pumpEventQueue();

    // Another LibreChat account, whose server has a chat with the same id,
    // takes over and opens it while the edits wait for the chat.
    container.read(_otherAccountProvider.notifier).set(true);
    final theirs = withChatStorageProvenance(
      Conversation(
        id: 'lc-1',
        title: 'Their chat',
        createdAt: DateTime.utc(2026, 10, 18),
        updatedAt: DateTime.utc(2026, 10, 18),
      ),
      ChatStorageKind.libreChat,
    );
    container.read(activeConversationProvider.notifier).set(theirs);
    gate.complete();
    await edits;

    check(container.read(activeConversationProvider)?.title).equals(
      'Their chat',
    );
    // The edits still reached the account they were made for.
    final row = (await libreChatDb.chatsDao.getChat('lc-1'))!;
    check(row.title).equals('Renamed before');
    check(row.deleted).isTrue();
  });

  test('a title written across an account switch leaves the new '
      'account\'s chat alone', () async {
    await pull();
    final locks = container.read(libreChatChatLocksProvider);
    final gate = Completer<void>();
    unawaited(locks.runExclusive('lc-1', () => gate.future));
    container
        .read(conversationsProvider.notifier)
        .applyLibreChatGeneratedTitle('lc-1', 'Generated title');
    await pumpEventQueue();

    // Another LibreChat account, whose server has a chat with the same id,
    // takes over and opens it while the title waits for the chat.
    container.read(_otherAccountProvider.notifier).set(true);
    final theirs = withChatStorageProvenance(
      Conversation(
        id: 'lc-1',
        title: 'Their chat',
        createdAt: DateTime.utc(2026, 10, 18),
        updatedAt: DateTime.utc(2026, 10, 18),
      ),
      ChatStorageKind.libreChat,
    );
    container.read(activeConversationProvider.notifier).set(theirs);
    gate.complete();
    await locks.runExclusive('lc-1', () async {});
    await pumpEventQueue();

    check(container.read(activeConversationProvider)?.title).equals(
      'Their chat',
    );
    // The title still reached the account it was made for.
    check(
      (await libreChatDb.chatsDao.getChat('lc-1'))!.title,
    ).equals('Generated title');
  });

  test('share and clone stay unavailable for LibreChat chats', () async {
    final scoped = const ChatStorageIdentity(
      rawId: 'lc-1',
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    await check(shareConversation(container, scoped)).throws<StateError>();
    await check(cloneConversation(container, scoped)).throws<StateError>();
  });

  test('a chat read across an account switch is never handed out', () async {
    final gate = Completer<void>();
    fake.on('GET', '/api/convos/lc-2', (request, match) async {
      await gate.future;
      return FakeLibreChatResponse.json(fake.conversations['lc-2']);
    });
    final subscription = container.listen(
      loadConversationProvider('lc-2'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    final load = container.read(loadConversationProvider('lc-2').future);
    await pumpEventQueue();
    // Another LibreChat account takes over while the chat is fetched.
    container.read(_otherAccountProvider.notifier).set(true);
    gate.complete();
    await check(load).throws<LibreChatAccountChangedException>();
  });

  test('a chat fetched across an account switch lands in its own account',
      () async {
    await pull();
    final engine = container.read(libreChatSyncEngineProvider)!;
    // Another account takes over: the engine's provider is rebuilt, and the
    // engine left with the old one can no longer hold its database there.
    container.read(_otherAccountProvider.notifier).set(true);
    check(
      container.read(libreChatSyncEngineProvider),
    ).not((it) => it.identicalTo(engine));
    fake.addConversation(
      'lc-3',
      title: 'Late',
      updatedAt: now,
      messageList: _turn('lc-3'),
    );

    // A fetch it was already asked for still goes on, unheld.
    check(await engine.pullChat('lc-3')).isTrue();
    check((await libreChatDb.chatsDao.getChat('lc-3'))?.title).equals('Late');
    check(await otherAccountDb.chatsDao.getChat('lc-3')).isNull();
  });

  test('a quick return to an account keeps the locks its database had',
      () async {
    final before = container.read(libreChatChatLocksProvider);
    container.read(_otherAccountProvider.notifier).set(true);
    check(
      container.read(libreChatChatLocksProvider),
    ).not((it) => it.identicalTo(before));
    // Back before the first account's database was let go: work still
    // holding it and work from now on lock its chats alike.
    container.read(_otherAccountProvider.notifier).set(false);
    check(container.read(libreChatChatLocksProvider)).identicalTo(before);
  });

  test('a LibreChat chat is not fetched while Open WebUI owns the tab',
      () async {
    container.read(preferredBackendProvider);
    preferred.choose(PreferredBackend.owui);
    // The LibreChat account stays signed in, its engine ready to pull.
    check(container.read(libreChatSyncEngineProvider)).isNotNull();
    final scoped = const ChatStorageIdentity(
      rawId: 'lc-2',
      storage: ChatStorageKind.libreChat,
    ).scopedId;
    await check(
      container.read(loadConversationProvider(scoped).future),
    ).throws<StateError>();
    check(
      fake.requests.map((request) => request.path),
    ).not((it) => it.contains('/api/messages/lc-2'));
    check(await libreChatDb.chatsDao.getChat('lc-2')).isNull();
  });

  test('search follows the account that owns the Chats tab', () async {
    await pull();
    final subscription = container.listen(
      serverSearchProvider('Question'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    check(
      (await container.read(serverSearchProvider('Question').future)).map(
        (conversation) => conversation.id,
      ),
    ).unorderedEquals(['lc-1', 'lc-2']);

    container.read(_otherAccountProvider.notifier).set(true);
    check(
      await container.read(serverSearchProvider('Question').future),
    ).isEmpty();
  });

  test('search typed before history arrives fills in and stays current',
      () async {
    final subscription = container.listen(
      serverSearchProvider('Question'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    check(
      await container.read(serverSearchProvider('Question').future),
    ).isEmpty();

    Future<Map<String, String>> titles() async {
      await _searchSettled();
      final results = await container.read(
        serverSearchProvider('Question').future,
      );
      return {
        for (final conversation in results)
          conversation.id: conversation.title,
      };
    }

    await pull();
    check(
      await titles(),
    ).deepEquals({'lc-1': 'Paris weather', 'lc-2': 'Recipes'});

    await libreChatDb.chatsDao.updateEnvelopeWithOutbox(
      'lc-1',
      title: const Value('Renamed here'),
      enqueue: true,
    );
    check(
      await titles(),
    ).deepEquals({'lc-1': 'Renamed here', 'lc-2': 'Recipes'});
  });

  test('search fills in once the index is built after chats land', () async {
    final subscription = container.listen(
      serverSearchProvider('webui'),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await libreChatDb.chatsDao.upsertServerChat(rows: _owuiRows('lc-9'));
    await _searchSettled();
    check(
      await container.read(serverSearchProvider('webui').future),
    ).isEmpty();

    await libreChatDb.buildFtsIfNeeded();
    await _searchSettled();
    check(
      (await container.read(serverSearchProvider('webui').future)).map(
        (conversation) => conversation.id,
      ),
    ).deepEquals(['lc-9']);
  });

  test('a burst of chat writes reruns search once', () async {
    await pull();
    var runs = 0;
    final subscription = container.listen(
      serverSearchProvider('Question'),
      (_, next) {
        if (next.isLoading) runs++;
      },
    );
    addTearDown(subscription.close);
    await container.read(serverSearchProvider('Question').future);
    await _searchSettled();
    runs = 0;

    for (var i = 0; i < 5; i++) {
      await libreChatDb.chatsDao.updateEnvelope(
        'lc-1',
        title: Value('Renamed $i'),
      );
      await pumpEventQueue();
    }
    await _searchSettled();
    check(runs).equals(1);
    check(
      (await container.read(serverSearchProvider('Question').future))
          .firstWhere((conversation) => conversation.id == 'lc-1')
          .title,
    ).equals('Renamed 4');
  });

  test('a sync cycle sends changes still queued', () async {
    await pull();
    await libreChatDb.chatsDao.updateEnvelopeWithOutbox(
      'lc-1',
      title: const Value('Queued title'),
      enqueue: true,
    );
    await pull();
    check(fake.conversations['lc-1']!['title']).equals('Queued title');
  });

  test('regained connectivity retries a change waiting out its delay', () async {
    await pull();
    var failures = 1;
    fake.on('POST', '/api/convos/update', (request, match) {
      if (failures-- > 0) {
        return FakeLibreChatResponse.json({'message': 'busy'}, statusCode: 503);
      }
      final arg = (request.data as Map)['arg'] as Map;
      fake.conversations[arg['conversationId']]!['title'] = arg['title'];
      return FakeLibreChatResponse.json(fake.conversations[arg['conversationId']]);
    });
    await libreChatDb.chatsDao.updateEnvelopeWithOutbox(
      'lc-1',
      title: const Value('Retried title'),
      enqueue: true,
    );
    final sync = container.read(primarySyncProvider);
    await sync.drainOutbox();
    // The failure scheduled a later attempt; a plain drain leaves it there.
    check(fake.conversations['lc-1']!['title']).equals('Paris weather');
    await sync.drainNow();
    check(fake.conversations['lc-1']!['title']).equals('Retried title');
  });
}
