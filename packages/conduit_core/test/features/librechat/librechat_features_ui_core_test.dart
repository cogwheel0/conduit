import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/server_speech/server_speech_providers.dart';
import 'package:conduit_core/features/chat/utils/chat_share_url.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/providers/librechat_memories_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_server_speech.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
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
import 'package:drift/drift.dart' show driftRuntimeOptions;
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
  late AppDatabase owuiDb;
  late AppDatabase directDb;
  late ProviderContainer container;
  // The real date: sessions the fake server issues are checked against the
  // real clock, and would lapse against a fixed one.
  final now = DateTime.now().toUtc();

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() async {
    PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
    await PreferencesStore.ensureInitialized();
    fake = FakeLibreChatServer(clock: () => now)..addUser();
    libreChatDb = AppDatabase(NativeDatabase.memory());
    owuiDb = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
    await owuiDb.chatsDao.upsertServerChat(rows: _owuiRows('owui-chat'));

    container = ProviderContainer(
      overrides: [
        // Open WebUI's store is open and populated, as at the moment a
        // switch completes: it must still never be consulted.
        ...openWebUiStorageOpenOverrides(database: owuiDb),
        preferredBackendProvider.overrideWith(
          () => _Preferred(PreferredBackend.libreChat),
        ),
        secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
        libreChatHttpAdapterProvider.overrideWithValue(fake),
        libreChatDatabaseProvider.overrideWith((ref) {
          final session = ref.watch(libreChatSessionProvider).asData?.value;
          return session is LibreChatSignedInState ? libreChatDb : null;
        }),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        isOnlineProvider.overrideWithValue(true),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        reviewerModeProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(null),
        apiServiceProvider.overrideWithValue(null),
        syncEngineProvider.overrideWith(_IdleSyncEngine.new),
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

  Future<Conversation> listedChat(String id) async {
    await pull();
    container.invalidate(conversationsProvider);
    final conversations = await container.read(conversationsProvider.future);
    return conversations.singleWhere((conversation) => conversation.id == id);
  }

  group('share links', () {
    test('create, re-snapshot and delete a LibreChat link', () async {
      String? linked;
      fake
        ..on(
          'GET',
          '/api/share/link/lc-1',
          (request, match) => FakeLibreChatResponse.json({
            'success': linked != null,
            'shareId': linked,
          }),
        )
        ..on('POST', '/api/share/lc-1', (request, match) {
          linked = 's1';
          return FakeLibreChatResponse.json({'shareId': 's1'});
        })
        ..on('PATCH', '/api/share/s1', (request, match) {
          linked = 's2';
          return FakeLibreChatResponse.json({'shareId': 's2'});
        })
        ..on('DELETE', '/api/share/s2', (request, match) {
          linked = null;
          return FakeLibreChatResponse.json({'success': true});
        });
      final conversation = await listedChat('lc-1');
      final id = conversationScopedId(conversation);

      final first = await shareConversationLink(container, id);
      check(first.shareId).equals('s1');
      check(first.url).equals('https://chat.example.com/share/s1');
      check(
        (await libreChatDb.chatsDao.getChat('lc-1'))!.shareId,
      ).equals('s1');

      // An existing link is snapshotted again, under a new id.
      final second = await shareConversationLink(container, id);
      check(second.url).equals('https://chat.example.com/share/s2');

      await deleteConversationShareLink(container, id);
      check(linked).isNull();
      check((await libreChatDb.chatsDao.getChat('lc-1'))!.shareId).isNull();
      // Nothing went to Open WebUI's store.
      check(await owuiDb.chatsDao.getChat('lc-1')).isNull();
    });

    test('a link the chat has survives the chat syncing again', () async {
      fake
        ..on(
          'GET',
          '/api/share/link/lc-1',
          (request, match) => FakeLibreChatResponse.json({'success': false}),
        )
        ..on(
          'POST',
          '/api/share/lc-1',
          (request, match) => FakeLibreChatResponse.json({'shareId': 's1'}),
        );
      final conversation = await listedChat('lc-1');
      await shareConversationLink(
        container,
        conversationScopedId(conversation),
      );

      // The chat changes on the server and is stored again.
      fake.addConversation(
        'lc-1',
        title: 'Paris weather, later',
        updatedAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        messageList: _turn('lc-1'),
      );
      await pull();
      final stored = (await libreChatDb.chatsDao.getChat('lc-1'))!;
      check(stored.title).equals('Paris weather, later');
      check(stored.shareId).equals('s1');
    });

    test('a LibreChat link honours a sub-path base', () {
      check(
        buildLibreChatShareUrl(
          baseUrl: 'https://example.com/librechat/',
          shareId: 'a b',
        ),
      ).equals('https://example.com/librechat/share/a%20b');
      check(
        () => buildLibreChatShareUrl(baseUrl: 'https://x.com', shareId: ' '),
      ).throws<FormatException>();
    });
  });

  group('fork and duplicate', () {
    Map<String, dynamic> copyOf(String id, String title) => {
      'conversation': {
        'conversationId': id,
        'title': title,
        'endpoint': 'Ollama',
        'createdAt': now.toIso8601String(),
        'updatedAt': now.toIso8601String(),
      },
      'messages': [
        for (final message in _turn(id)) {...message, 'conversationId': id},
      ],
    };

    test('a branch is stored and comes back ready to open', () async {
      fake.on(
        'POST',
        '/api/convos/fork',
        (request, match) => FakeLibreChatResponse.json(copyOf('lc-3', 'Fork')),
      );
      final conversation = await listedChat('lc-1');
      final copy = await copyLibreChatConversation(
        container,
        conversationScopedId(conversation),
        upToMessageId: 'lc-1-a',
      );
      check(copy.id).equals('lc-3');
      check(isLibreChatConversation(copy)).isTrue();
      final sent = fake.requests.last.data as Map;
      check(sent['conversationId']).equals('lc-1');
      check(sent['messageId']).equals('lc-1-a');
      final stored = await libreChatDb.chatsDao.getChat('lc-3');
      check(stored!.title).equals('Fork');
      check(stored.bodySynced).isTrue();
    });

    test('a duplicate copies the whole chat', () async {
      fake.on(
        'POST',
        '/api/convos/duplicate',
        (request, match) =>
            FakeLibreChatResponse.json(copyOf('lc-4', 'Paris weather (copy)')),
      );
      final conversation = await listedChat('lc-1');
      final copy = await copyLibreChatConversation(
        container,
        conversationScopedId(conversation),
      );
      check(copy.id).equals('lc-4');
      check(await libreChatDb.messagesDao.getForChat('lc-4')).length.equals(2);
    });

    test('branching is offered for an open LibreChat chat', () async {
      final conversation = await listedChat('lc-1');
      container.read(activeConversationProvider.notifier).set(conversation);
      check(
        container.read(chatForkAvailabilityProvider),
      ).equals(ChatForkAvailability.available);
    });
  });

  test('LibreChat chats speak through their server\'s engines', () async {
    fake.on(
      'GET',
      '/api/files/speech/config/get',
      (request, match) => FakeLibreChatResponse.json({
        'sttExternal': true,
        'ttsExternal': true,
      }),
    );
    final model = libreChatCatalog(
      startupConfig: const {},
      endpoints: const {
        'Ollama': {'type': 'custom'},
      },
      models: const {
        'Ollama': ['llama3.2'],
      },
    ).single;
    container.read(selectedModelProvider.notifier).set(model);
    await container.read(libreChatServerSpeechProvider.future);
    final speech = container.read(serverSpeechProviderProvider);
    check(speech).isA<LibreChatServerSpeech>()
      ..has((it) => it.canTranscribe, 'canTranscribe').isTrue()
      ..has((it) => it.canSynthesize, 'canSynthesize').isTrue();
  });

  test('LibreChat is on unless the preference turns it off', () async {
    check(container.read(libreChatBackendEnabledProvider)).isTrue();
    await PreferencesStore.put(kLibreChatBackendEnabledPreference, false);
    container.invalidate(libreChatBackendEnabledProvider);
    check(container.read(libreChatBackendEnabledProvider)).isFalse();
  });

  test('memories: list, add, edit, delete and the switch', () async {
    final memories = <String, String>{'work': 'Engineer'};
    var enabled = true;
    fake
      ..on(
        'GET',
        '/api/memories',
        (request, match) => FakeLibreChatResponse.json({
          'memories': [
            for (final entry in memories.entries)
              {'key': entry.key, 'value': entry.value, 'tokenCount': 4},
          ],
          'totalTokens': memories.length * 4,
          'tokenLimit': 100,
        }),
      )
      ..on('POST', '/api/memories', (request, match) {
        final body = request.data as Map;
        if (memories.containsKey(body['key'])) {
          return FakeLibreChatResponse.json({
            'error': 'Memory with this key already exists.',
          }, statusCode: 409);
        }
        memories[body['key'] as String] = body['value'] as String;
        return FakeLibreChatResponse.json({'created': true}, statusCode: 201);
      })
      ..on('PATCH', '/api/memories/([^/]+)', (request, match) {
        final body = request.data as Map;
        final key = Uri.decodeComponent(match.group(1)!);
        memories.remove(key);
        memories[(body['key'] ?? key) as String] = body['value'] as String;
        return FakeLibreChatResponse.json({'updated': true});
      })
      ..on('DELETE', '/api/memories/([^/]+)', (request, match) {
        memories.remove(Uri.decodeComponent(match.group(1)!));
        return FakeLibreChatResponse.json({'deleted': true});
      })
      // Registered last so it wins over the key route, as the server's own
      // route does.
      ..on('PATCH', '/api/memories/preferences', (request, match) {
        enabled = (request.data as Map)['memories'] as bool;
        return FakeLibreChatResponse.json({'updated': true});
      });

    final notifier = container.read(libreChatMemoriesProvider.notifier);
    var state = await container.read(libreChatMemoriesProvider.future);
    check(state.enabled).isTrue();
    check(state.memories.memories.single.key).equals('work');
    check(state.memories.usage).equals(0.04);

    await notifier.save(key: 'tone', value: 'Concise');
    await notifier.save(originalKey: 'work', key: 'job', value: 'Designer');
    state = await container.read(libreChatMemoriesProvider.future);
    check({
      for (final memory in state.memories.memories) memory.key: memory.value,
    }).deepEquals({'tone': 'Concise', 'job': 'Designer'});

    // The server's reason comes back for the page to show.
    Object? refused;
    try {
      await notifier.save(key: 'tone', value: 'Again');
    } catch (error) {
      refused = error;
    }
    check(refused).isA<LibreChatApiException>().has(
      (it) => it.message,
      'message',
    ).equals('Memory with this key already exists.');

    await notifier.delete('tone');
    await notifier.setEnabled(false);
    state = await container.read(libreChatMemoriesProvider.future);
    check(state.memories.memories.single.key).equals('job');
    check(enabled).isFalse();
    check(state.enabled).isFalse();

    // A write the server accepted reports success even when reading the
    // list back fails; the list shows the error instead.
    fake.on(
      'GET',
      '/api/memories',
      (request, match) =>
          FakeLibreChatResponse.json({'error': 'down'}, statusCode: 503),
    );
    await notifier.save(key: 'city', value: 'Lisbon');
    check(memories['city']).equals('Lisbon');
  });
}
