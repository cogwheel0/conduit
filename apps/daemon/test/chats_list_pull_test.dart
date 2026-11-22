@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider, directLocalDatabaseProvider;
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
import 'package:conduit_core/sync/chat_locks.dart' show chatLocksProvider;
import 'package:conduit_core/sync/pull_sync.dart' show PullResult;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, driftRuntimeOptions;
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

/// Fails every read mark's write, as a full disk would.
final class _FailingReadMarks extends QueryInterceptor {
  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.contains('last_read_at')) {
      throw StateError('database or disk is full');
    }
    return executor.runUpdate(statement, args);
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

  test('a read that could not be stored is answered as a failure, which a '
      'quitting window logs', () async {
    final warned = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warned,
    );
    final failing = AppDatabase(
      NativeDatabase.memory().interceptWith(_FailingReadMarks()),
    );
    addTearDown(failing.close);
    final scoped = ProviderContainer(
      overrides: [
        syncEngineProvider.overrideWith(() => engine),
        conversationsProvider.overrideWith(_Conversations.new),
        foldersProvider.overrideWith(_Folders.new),
        currentUserProvider2.overrideWithValue(null),
        appDatabaseProvider.overrideWith((ref) => failing),
      ],
    );
    addTearDown(scoped.dispose);

    await expectLater(
      ChatsService(scoped)
          .markUnread(const MarkUnread(chatId: 'chat-a', unread: false)),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.serverError,
        ),
      ),
    );
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

  // CodeRabbit 4651867121: a pull's write of what it read before a pin or
  // archive made here could land between that change and its note.
  test('an Open WebUI pin or archive made here is noted before the chat is '
      'free for a pull to write', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final owui = _OwuiApi();
    addTearDown(owui.dispose);
    final scoped = ProviderContainer(
      overrides: [
        syncEngineProvider.overrideWith(() => engine),
        conversationsProvider.overrideWith(_Conversations.new),
        foldersProvider.overrideWith(_Folders.new),
        currentUserProvider2.overrideWithValue(null),
        primaryAccountKindProvider.overrideWithValue(
          PrimaryAccountKind.openWebUi,
        ),
        appDatabaseProvider.overrideWithValue(db),
        apiServiceProvider.overrideWithValue(owui),
      ],
    );
    addTearDown(scoped.dispose);
    final locks = scoped.read(chatLocksProvider);
    // A pull's write, queued for the chat while the server takes the
    // change, checks as the pull does whether the chat changed here since
    // the pull began.
    final changedHere = <bool>[];
    owui.whileWriting = (id) {
      final since = db.chatsDao.localEnvelopeClock;
      unawaited(
        locks.runExclusive(
          id,
          () async =>
              changedHere.add(db.chatsDao.envelopeChangedSince(id, since)),
        ),
      );
    };
    final service = ChatsService(scoped, now: () => now);

    await service.setPinned('srv-chat', value: true);
    await service.setArchived('srv-chat', value: true);
    await locks.runExclusive('srv-chat', () async {});

    expect(owui.toggles, ['pin srv-chat', 'archive srv-chat']);
    expect(changedHere, [true, true]);
  });

  // Macroscope 4652079206: a pin that waited for the chat while another
  // account took over went to that account, and was noted in its database.
  test('an Open WebUI pin or archive stays with the account that asked for '
      'it', () async {
    final warned = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warned,
    );
    final first = (api: _OwuiApi(), db: AppDatabase(NativeDatabase.memory()));
    final second = (api: _OwuiApi(), db: AppDatabase(NativeDatabase.memory()));
    for (final account in [first, second]) {
      addTearDown(account.db.close);
      addTearDown(account.api.dispose);
    }
    var account = first;
    var epoch = Object();
    final scoped = ProviderContainer(
      overrides: [
        syncEngineProvider.overrideWith(() => engine),
        conversationsProvider.overrideWith(_Conversations.new),
        foldersProvider.overrideWith(_Folders.new),
        currentUserProvider2.overrideWithValue(null),
        primaryAccountKindProvider.overrideWithValue(
          PrimaryAccountKind.openWebUi,
        ),
        appDatabaseProvider.overrideWith((ref) => account.db),
        apiServiceProvider.overrideWith((ref) => account.api),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
      ],
    );
    addTearDown(scoped.dispose);
    void takeOver(({_OwuiApi api, AppDatabase db}) next) {
      account = next;
      epoch = Object();
      scoped
        ..invalidate(appDatabaseProvider)
        ..invalidate(apiServiceProvider)
        ..invalidate(openWebUiAuthSessionEpochProvider);
    }

    final service = ChatsService(scoped, now: () => now);

    // The second account takes over while the pin waits for the chat.
    final busy = Completer<void>();
    unawaited(
      scoped
          .read(chatLocksProvider)
          .runExclusive('srv-chat', () => busy.future),
    );
    final waiting = service.setPinned('srv-chat', value: true);
    takeOver(second);
    busy.complete();
    await expectLater(
      waiting,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    expect(first.api.toggles, isEmpty);
    expect(second.api.toggles, isEmpty);

    // The first takes over again while the server takes the second's
    // archive.
    second.api.whileWriting = (_) => takeOver(first);
    await service.setArchived('srv-chat', value: true);

    expect(second.api.toggles, ['archive srv-chat']);
    expect(second.db.chatsDao.envelopeChangedSince('srv-chat', 0), isTrue);
    expect(first.db.chatsDao.envelopeChangedSince('srv-chat', 0), isFalse);
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

  /// Runs while the server takes a pin or archive of chat `id`.
  void Function(String id)? whileWriting;

  @override
  Future<void> pinConversation(String id, bool pinned) async {
    whileWriting?.call(id);
    toggles.add('pin $id');
  }

  @override
  Future<void> archiveConversation(String id, bool archived) async {
    whileWriting?.call(id);
    toggles.add('archive $id');
  }
}
