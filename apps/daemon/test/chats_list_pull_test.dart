@TestOn('vm')
library;

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart'
    show directLocalDatabaseProvider;
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatDatabaseProvider;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show primaryAccountKindProvider, PrimaryAccountKind;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/sync/pull_sync.dart' show PullResult;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduitd/conduitd.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A sync engine whose pulls fail while [reachable] is false, as they do
/// with the server out of reach.
final class _Engine extends SyncEngine {
  var reachable = false;
  var pulls = 0;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<PullResult?> requestPull({required String reason}) async {
    pulls++;
    state = SyncStatus(lastError: reachable ? null : 'pull failed');
    return null;
  }
}

final class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

final class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];
}

void main() {
  late _Engine engine;
  late ProviderContainer container;
  late DateTime now;
  late ChatsService chats;

  setUp(() {
    engine = _Engine();
    container = ProviderContainer(
      overrides: [
        syncEngineProvider.overrideWith(() => engine),
        conversationsProvider.overrideWith(_Conversations.new),
        foldersProvider.overrideWith(_Folders.new),
        currentUserProvider2.overrideWithValue(null),
      ],
    );
    now = DateTime(2026, 11, 9, 12);
    chats = ChatsService(container, now: () => now);
  });

  tearDown(() => container.dispose());

  Future<void> list() async {
    await chats.list();
    // The pull runs in the background.
    await Future<void>.delayed(Duration.zero);
  }

  test('a list soon after a successful pull does not pull again', () async {
    engine.reachable = true;
    await list();
    now = now.add(const Duration(seconds: 5));
    await list();
    expect(engine.pulls, 1);

    now = now.add(const Duration(seconds: 30));
    await list();
    expect(engine.pulls, 2);
  });

  test('a list after a failed pull pulls again, so the server coming back '
      'is caught up at once', () async {
    // Launched with the server out of reach.
    await list();
    expect(engine.pulls, 1);

    // It is back; the window lists again a few seconds later.
    engine.reachable = true;
    now = now.add(const Duration(seconds: 5));
    await list();
    expect(engine.pulls, 2);

    // That one succeeded: the floor holds again.
    now = now.add(const Duration(seconds: 5));
    await list();
    expect(engine.pulls, 2);
  });

  test('a LibreChat chat not listed yet is pinned and archived in LibreChat', () async {
    // LibreChat is in charge; Open WebUI's account is still signed in
    // behind it.
    final warned = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warned,
    );
    final libreChat = AppDatabase(NativeDatabase.memory());
    addTearDown(libreChat.close);
    final direct = AppDatabase(NativeDatabase.memory());
    addTearDown(direct.close);
    final owui = _OwuiApi();
    addTearDown(owui.dispose);
    final scoped = ProviderContainer(
      overrides: [
        syncEngineProvider.overrideWith(() => engine),
        conversationsProvider.overrideWith(_Conversations.new),
        foldersProvider.overrideWith(_Folders.new),
        currentUserProvider2.overrideWithValue(null),
        primaryAccountKindProvider.overrideWithValue(
          PrimaryAccountKind.libreChat,
        ),
        libreChatDatabaseProvider.overrideWithValue(libreChat),
        directLocalDatabaseProvider.overrideWithValue(direct),
        apiServiceProvider.overrideWithValue(owui),
      ],
    );
    addTearDown(scoped.dispose);
    // A copy just made: in LibreChat's store, not in the list yet.
    await libreChat.chatsDao.upsertServerChat(
      rows: ChatBlobMapper.blobToRows(
        chatId: 'lc-copy',
        blob: <String, dynamic>{
          'title': 'Seed swap (copy)',
          'history': <String, dynamic>{
            'messages': <String, dynamic>{},
            'currentId': null,
          },
        },
        title: 'Seed swap (copy)',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    final service = ChatsService(scoped, now: () => now);

    await service.setPinned('lc-copy', value: true);
    await service.setArchived('lc-copy', value: true);

    expect(owui.toggles, isEmpty, reason: 'sent to Open WebUI');
    final row = await libreChat.chatsDao.getChat('lc-copy');
    expect(row?.pinned, isTrue);
    expect(row?.archived, isTrue);
  });
}

/// Open WebUI's client, which takes no LibreChat chat's pin or archive.
final class _OwuiApi extends ApiService {
  _OwuiApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'server-owui',
          name: 'Garden server',
          url: 'https://garden.invalid',
        ),
        workerManager: WorkerManager(),
      );

  final toggles = <String>[];

  @override
  Future<void> pinConversation(String id, bool pinned) async =>
      toggles.add('pin $id');

  @override
  Future<void> archiveConversation(String id, bool archived) async =>
      toggles.add('archive $id');
}
