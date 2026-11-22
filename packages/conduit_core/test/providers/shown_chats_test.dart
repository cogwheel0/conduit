/// A chat on screen is being read: when its stored copy changes while a view
/// shows it (the server's own save of a finished answer, brought by a pull),
/// it is read up to that copy, here and on the server, once per change.
library;

import 'dart:async';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase serverDb;
  late AppDatabase directDb;
  late _ReadsSocket socket;
  late bool previousDontWarn;

  setUpAll(() {
    previousDontWarn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDontWarn;
  });

  setUp(() {
    serverDb = AppDatabase(NativeDatabase.memory());
    directDb = AppDatabase(NativeDatabase.memory());
    socket = _ReadsSocket();
  });

  tearDown(() async {
    await serverDb.close();
    await directDb.close();
  });

  /// A container whose Open WebUI chats are kept in the database
  /// [_activeDatabaseProvider] holds, [serverDb] at first.
  Future<ProviderContainer> signedIn() async {
    final container = ProviderContainer(
      overrides: [
        openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
        _activeDatabaseProvider.overrideWith(() => _ActiveDatabase(serverDb)),
        appDatabaseProvider.overrideWith(
          (ref) => ref.watch(_activeDatabaseProvider),
        ),
        directLocalDatabaseProvider.overrideWithValue(directDb),
        activeConversationProvider.overrideWith(_ActiveConversation.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
        socketServiceProvider.overrideWithValue(socket),
        syncEngineProvider.overrideWith(_QuietSyncEngine.new),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {},
        ),
        apiServiceProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(conversationsProvider.future);
    return container;
  }

  /// Completes once the chat list shows [id] dated [updatedAt] (epoch
  /// seconds). Every listener the list had before this one has been told
  /// by then.
  Future<void> listedAt(ProviderContainer container, String id, int updatedAt) {
    final seen = Completer<void>();
    late final ProviderSubscription<AsyncValue<List<Conversation>>> sub;
    sub = container.listen<AsyncValue<List<Conversation>>>(
      conversationsProvider,
      (_, next) {
        final chat = next.asData?.value.where((c) => c.id == id).firstOrNull;
        if (chat != null &&
            chat.updatedAt.millisecondsSinceEpoch == updatedAt * 1000 &&
            !seen.isCompleted) {
          seen.complete();
          sub.close();
        }
      },
      fireImmediately: true,
    );
    return seen.future;
  }

  /// The stored read of [id] in [db], once it covers [updatedAt].
  Future<int> storedReadThrough(AppDatabase db, String id, int updatedAt) => db
      .chatsDao
      .watchChatMeta(id)
      .map((entry) => entry?.lastReadAt ?? -1)
      .firstWhere((read) => read >= updatedAt);

  Future<int?> storedRead(AppDatabase db, String id) async =>
      (await db.chatsDao.getChat(id))?.lastReadAt;

  /// A pull brings [id] as the server last saved it, dated [updatedAt]: an
  /// answer Open WebUI finished and saved itself.
  Future<void> serverSaved(AppDatabase db, String id, int updatedAt) =>
      db.chatsDao.upsertServerChat(rows: _rows(id, updatedAt: updatedAt));

  test('a chat on screen is read when its stored copy changes, here and on '
      'the server, once per change', () async {
    await serverDb.chatsDao.upsertServerChat(
      rows: _rows('chat-s', updatedAt: 100),
      listLastReadAt: 100,
    );
    final container = await signedIn();
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');

    final listed = listedAt(container, 'chat-s', 160);
    await serverSaved(serverDb, 'chat-s', 160);
    await listed;
    expect(socket.reads, <String>['chat-s']);
    expect(await storedReadThrough(serverDb, 'chat-s', 160), greaterThan(159));

    // Nothing more for the same copy, whatever else changes.
    await serverDb.chatsDao.upsertServerChat(
      rows: _rows('chat-other', updatedAt: 170),
    );
    await listedAt(container, 'chat-other', 170);
    expect(socket.reads, <String>['chat-s']);

    // The next change is read too.
    final again = listedAt(container, 'chat-s', 4000000000);
    await serverSaved(serverDb, 'chat-s', 4000000000);
    await again;
    expect(socket.reads, <String>['chat-s', 'chat-s']);
    expect(
      await storedReadThrough(serverDb, 'chat-s', 4000000000),
      4000000000,
      reason: 'a copy dated past this device\'s clock stays unread',
    );
  });

  test(
    'a chat no view shows keeps its mark: one left, or never shown',
    () async {
      await serverDb.chatsDao.upsertServerChat(
        rows: _rows('chat-a', updatedAt: 100),
        listLastReadAt: 100,
      );
      await serverDb.chatsDao.upsertServerChat(
        rows: _rows('chat-b', updatedAt: 100),
        listLastReadAt: 100,
      );
      final container = await signedIn();
      final shown = container.read(shownChatsProvider.notifier)
        ..show('main', 'chat-a');

      final b = listedAt(container, 'chat-b', 160);
      await serverSaved(serverDb, 'chat-b', 160);
      await b;
      expect(await storedRead(serverDb, 'chat-b'), 100);

      // An answer that finishes once the chat is no longer on screen.
      shown.show('main', null);
      final a = listedAt(container, 'chat-a', 170);
      await serverSaved(serverDb, 'chat-a', 170);
      await a;
      expect(await storedRead(serverDb, 'chat-a'), 100);
      expect(socket.reads, isEmpty);
    },
  );

  test('each view shows its own chat', () async {
    await serverDb.chatsDao.upsertServerChat(
      rows: _rows('chat-a', updatedAt: 100),
      listLastReadAt: 100,
    );
    await serverDb.chatsDao.upsertServerChat(
      rows: _rows('chat-q', updatedAt: 100),
      listLastReadAt: 100,
    );
    final container = await signedIn();
    container.read(shownChatsProvider.notifier)
      ..show('main', 'chat-a')
      ..show('quick-ask', 'chat-q')
      ..show('quick-ask', null);

    final a = listedAt(container, 'chat-a', 160);
    await serverSaved(serverDb, 'chat-a', 160);
    await a;
    expect(socket.reads, <String>['chat-a']);
    expect(await storedReadThrough(serverDb, 'chat-a', 160), greaterThan(159));

    final q = listedAt(container, 'chat-q', 170);
    await serverSaved(serverDb, 'chat-q', 170);
    await q;
    expect(await storedRead(serverDb, 'chat-q'), 100);
    expect(socket.reads, <String>['chat-a']);
  });

  test('a chat marked unread stays unread while it shows, until it is read '
      'again', () async {
    await serverDb.chatsDao.upsertServerChat(
      rows: _rows('chat-s', updatedAt: 100),
      listLastReadAt: 100,
    );
    final container = await signedIn();
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');
    final previous = await serverDb.chatsDao.markUnread('chat-s');
    await serverDb.chatsDao.finishUnread(
      'chat-s',
      refused: false,
      previous: previous,
    );

    final listed = listedAt(container, 'chat-s', 160);
    await serverSaved(serverDb, 'chat-s', 160);
    await listed;
    expect(await storedRead(serverDb, 'chat-s'), 0);
    expect(socket.reads, isEmpty);

    // Opened again: read, and kept read from then on.
    expect(
      await markConversationRead(
        container,
        'chat-s',
        readAt: DateTime.fromMillisecondsSinceEpoch(200 * 1000),
      ),
      isTrue,
    );
    final later = listedAt(container, 'chat-s', 4000000000);
    await serverSaved(serverDb, 'chat-s', 4000000000);
    await later;
    expect(socket.reads, <String>['chat-s', 'chat-s']);
    expect(await storedReadThrough(serverDb, 'chat-s', 4000000000), 4000000000);
  });

  test('no read goes to another account, even for the same chat id', () async {
    await serverDb.chatsDao.upsertServerChat(
      rows: _rows('chat-s', updatedAt: 100),
      listLastReadAt: 100,
    );
    final otherDb = AppDatabase(NativeDatabase.memory());
    addTearDown(otherDb.close);
    await otherDb.chatsDao.upsertServerChat(
      rows: _rows('chat-s', updatedAt: 100),
      listLastReadAt: 100,
    );
    final container = await signedIn();
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');

    container.read(_activeDatabaseProvider.notifier).set(otherDb);
    await container.read(conversationsProvider.future);
    final listed = listedAt(container, 'chat-s', 160);
    await serverSaved(otherDb, 'chat-s', 160);
    await listed;
    expect(await storedRead(otherDb, 'chat-s'), 100);
    expect(socket.reads, isEmpty);
  });
}

ChatRows _rows(String id, {required int updatedAt}) {
  return ChatBlobMapper.blobToRows(
    chatId: id,
    blob: {
      'title': 'Tide tables',
      'history': {
        'currentId': '$id-m1',
        'messages': {
          '$id-m1': {
            'id': '$id-m1',
            'parentId': null,
            'childrenIds': <String>[],
            'role': 'user',
            'content': 'when is the next low tide',
            'timestamp': updatedAt,
          },
        },
      },
    },
    title: 'Tide tables',
    createdAt: 100,
    updatedAt: updatedAt,
  );
}

/// Records the reads sent to the server.
final class _ReadsSocket extends SocketService {
  _ReadsSocket()
    : super(
        serverConfig: const ServerConfig(
          id: 'server',
          name: 'Server',
          url: 'https://example.test',
        ),
      );

  final List<String> reads = <String>[];

  @override
  bool get isConnected => true;

  @override
  void emit(String event, dynamic data) {
    if (event == 'events:chat' &&
        data is Map &&
        data['data'] is Map &&
        (data['data'] as Map)['type'] == 'last_read_at') {
      reads.add('${data['chat_id']}');
    }
  }
}

final class _ActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

final class _QuietSyncEngine extends SyncEngine {
  @override
  Future<PullResult?> requestPull({required String reason}) =>
      Future<PullResult?>.value(null);
}

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

/// The Open WebUI database of the signed-in account, switchable mid-test.
final class _ActiveDatabase extends Notifier<AppDatabase> {
  _ActiveDatabase(this.initial);

  final AppDatabase initial;

  @override
  AppDatabase build() => initial;

  void set(AppDatabase database) => state = database;
}

final _activeDatabaseProvider = NotifierProvider<_ActiveDatabase, AppDatabase>(
  () => throw UnimplementedError('override per test'),
);
