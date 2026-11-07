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
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
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
