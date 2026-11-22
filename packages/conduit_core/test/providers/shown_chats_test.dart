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

  /// Completes once the chat list satisfies [test]. A listener told at once
  /// (`fireImmediately`) may complete before its subscription is assigned,
  /// so it is closed once both have happened.
  Future<void> listShows(
    ProviderContainer container,
    bool Function(List<Conversation> chats) test,
  ) {
    final seen = Completer<void>();
    ProviderSubscription<AsyncValue<List<Conversation>>>? sub;
    sub = container.listen<AsyncValue<List<Conversation>>>(
      conversationsProvider,
      (_, next) {
        final chats = next.asData?.value;
        if (chats != null && test(chats) && !seen.isCompleted) {
          seen.complete();
          sub?.close();
        }
      },
      fireImmediately: true,
    );
    if (seen.isCompleted) sub.close();
    return seen.future;
  }

  /// Completes once [db] stores [id] dated [updatedAt] (epoch seconds). The
  /// core's watch of a shown chat's row is told of the change first: drift
  /// shares one stream between equal queries and calls its listeners in
  /// order.
  Future<void> storedAt(AppDatabase db, String id, int updatedAt) => db.chatsDao
      .watchChatMeta(id)
      .firstWhere((entry) => entry?.updatedAt == updatedAt);

  /// The stored read of [id] in [db], once it covers [updatedAt].
  Future<int> storedReadThrough(AppDatabase db, String id, int updatedAt) => db
      .chatsDao
      .watchChatMeta(id)
      .map((entry) => entry?.lastReadAt ?? -1)
      .firstWhere((read) => read >= updatedAt);

  Future<int?> storedRead(AppDatabase db, String id) async =>
      (await db.chatsDao.getChat(id))?.lastReadAt;

  /// Lets a read the core began from an earlier change reach [db]: the
  /// database runs statements in the order they come, and such a read looks
  /// the chat up once before it writes.
  Future<void> settled(AppDatabase db) async {
    await db.chatsDao.getChat('settled');
    await db.chatsDao.getChat('settled');
  }

  Future<void> seedRead(
    AppDatabase db,
    String id, {
    int at = 100,
    bool archived = false,
  }) => db.chatsDao.upsertServerChat(
    rows: _rows(id, updatedAt: at, archived: archived),
    listLastReadAt: at,
  );

  /// A pull brings [id] as the server last saved it, dated [updatedAt]: an
  /// answer Open WebUI finished and saved itself.
  Future<void> serverSaved(
    AppDatabase db,
    String id,
    int updatedAt, {
    bool archived = false,
  }) => db.chatsDao.upsertServerChat(
    rows: _rows(id, updatedAt: updatedAt, archived: archived),
  );

  test('a chat on screen is read when its stored copy changes, here and on '
      'the server, once per change', () async {
    await seedRead(serverDb, 'chat-s');
    final container = await signedIn();
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');

    await serverSaved(serverDb, 'chat-s', 160);
    expect(await storedReadThrough(serverDb, 'chat-s', 160), greaterThan(159));
    expect(socket.reads, <String>['chat-s']);

    // Nothing more for the same copy, whatever else changes.
    await serverSaved(serverDb, 'chat-other', 170);
    await settled(serverDb);
    expect(socket.reads, <String>['chat-s']);

    // The next change is read too.
    await serverSaved(serverDb, 'chat-s', 4000000000);
    expect(
      await storedReadThrough(serverDb, 'chat-s', 4000000000),
      4000000000,
      reason: 'a copy dated past this device\'s clock stays unread',
    );
    expect(socket.reads, <String>['chat-s', 'chat-s']);
  });

  test(
    'a chat no view shows keeps its mark: one left, or never shown',
    () async {
      await seedRead(serverDb, 'chat-a');
      await seedRead(serverDb, 'chat-b');
      final container = await signedIn();
      final shown = container.read(shownChatsProvider.notifier)
        ..show('main', 'chat-a');

      await serverSaved(serverDb, 'chat-b', 160);
      await settled(serverDb);
      expect(await storedRead(serverDb, 'chat-b'), 100);

      // An answer that finishes once the chat is no longer on screen.
      shown.show('main', null);
      await serverSaved(serverDb, 'chat-a', 170);
      await settled(serverDb);
      expect(await storedRead(serverDb, 'chat-a'), 100);
      expect(socket.reads, isEmpty);
    },
  );

  test('each view shows its own chat', () async {
    await seedRead(serverDb, 'chat-a');
    await seedRead(serverDb, 'chat-q');
    final container = await signedIn();
    container.read(shownChatsProvider.notifier)
      ..show('main', 'chat-a')
      ..show('quick-ask', 'chat-q')
      ..show('quick-ask', null);

    await serverSaved(serverDb, 'chat-a', 160);
    expect(await storedReadThrough(serverDb, 'chat-a', 160), greaterThan(159));
    expect(socket.reads, <String>['chat-a']);

    await serverSaved(serverDb, 'chat-q', 170);
    await settled(serverDb);
    expect(await storedRead(serverDb, 'chat-q'), 100);
    expect(socket.reads, <String>['chat-a']);
  });

  test('two views showing one chat read each change of it once', () async {
    await seedRead(serverDb, 'chat-s');
    final container = await signedIn();
    container.read(shownChatsProvider.notifier)
      ..show('main', 'chat-s')
      ..show('quick-ask', 'chat-s');

    await serverSaved(serverDb, 'chat-s', 160);
    expect(await storedReadThrough(serverDb, 'chat-s', 160), greaterThan(159));
    await settled(serverDb);
    expect(socket.reads, <String>['chat-s']);
  });

  test('a chat marked unread stays unread while it shows, until it is read '
      'again', () async {
    await seedRead(serverDb, 'chat-s');
    final container = await signedIn();
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');
    final previous = await serverDb.chatsDao.markUnread('chat-s');
    await serverDb.chatsDao.finishUnread(
      'chat-s',
      refused: false,
      previous: previous,
    );

    final seen = storedAt(serverDb, 'chat-s', 160);
    await serverSaved(serverDb, 'chat-s', 160);
    await seen;
    await settled(serverDb);
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
    await serverSaved(serverDb, 'chat-s', 4000000000);
    expect(await storedReadThrough(serverDb, 'chat-s', 4000000000), 4000000000);
    expect(socket.reads, <String>['chat-s', 'chat-s']);
  });

  // The user marks the chat unread just as the server's save of its answer
  // reaches the list, or the chat's own stored row, which the core is
  // reading it from.
  for (final reaches in ['the list', 'its stored row']) {
    test('a mark of unread made as a change reaches $reaches stays', () async {
      await seedRead(serverDb, 'chat-s');
      final container = await signedIn();
      container.read(shownChatsProvider.notifier).show('main', 'chat-s');
      final marking = Completer<int?>();
      void markOnce() {
        if (!marking.isCompleted) {
          marking.complete(serverDb.chatsDao.markUnread('chat-s'));
        }
      }

      if (reaches == 'the list') {
        final hook = container.listen<AsyncValue<List<Conversation>>>(
          conversationsProvider,
          (_, next) {
            final chat = next.asData?.value
                .where((c) => c.id == 'chat-s')
                .firstOrNull;
            if (chat?.updatedAt.millisecondsSinceEpoch == 160 * 1000) {
              markOnce();
            }
          },
        );
        addTearDown(hook.close);
      } else {
        final hook = serverDb.chatsDao.watchChatMeta('chat-s').listen((entry) {
          if (entry?.updatedAt == 160) markOnce();
        });
        addTearDown(hook.cancel);
      }

      await serverSaved(serverDb, 'chat-s', 160);
      final previous = await marking.future;
      await serverDb.chatsDao.finishUnread(
        'chat-s',
        refused: false,
        previous: previous,
      );
      await settled(serverDb);
      expect(await storedRead(serverDb, 'chat-s'), 0);
    });
  }

  test('a mark of unread the server refuses, written before the core looks '
      'the chat up, leaves the chat on screen to be read', () async {
    await seedRead(serverDb, 'chat-s');
    final container = await signedIn();
    final marking = Completer<int?>();
    // Told of the change before the core's watch: drift calls a shared
    // stream's listeners in order, so the mark is written before the core
    // looks the chat up, and the lookup finds it marked unread.
    final hook = serverDb.chatsDao.watchChatMeta('chat-s').listen((entry) {
      if (entry?.updatedAt == 160 && !marking.isCompleted) {
        marking.complete(serverDb.chatsDao.markUnread('chat-s'));
      }
    });
    addTearDown(hook.cancel);
    await storedAt(serverDb, 'chat-s', 100);
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');

    await serverSaved(serverDb, 'chat-s', 160);
    final previous = await marking.future;
    await settled(serverDb);
    expect(await storedRead(serverDb, 'chat-s'), 0);
    await serverDb.chatsDao.finishUnread(
      'chat-s',
      refused: true,
      previous: previous,
    );

    // The earlier read is back, and the copy on screen is newer than it.
    expect(await storedReadThrough(serverDb, 'chat-s', 160), greaterThan(159));
    expect(socket.reads, <String>['chat-s']);
  });

  test('an archived chat on screen is read when its stored copy changes, '
      'once the list no longer holds it', () async {
    await seedRead(serverDb, 'chat-s', archived: true);
    final container = await signedIn();
    final conversations = container.read(conversationsProvider.notifier);
    await conversations.setArchivedChatsVisible(true);
    await listShows(container, (chats) => chats.any((c) => c.id == 'chat-s'));
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');
    // Archived is collapsed while the chat stays on screen.
    await conversations.setArchivedChatsVisible(false);
    await listShows(container, (chats) => chats.every((c) => c.id != 'chat-s'));

    await serverSaved(serverDb, 'chat-s', 160, archived: true);
    expect(await storedReadThrough(serverDb, 'chat-s', 160), greaterThan(159));
    expect(socket.reads, <String>['chat-s']);
  });

  test('a chat on screen past the list\'s loaded page is read too, and read '
      'again when held unread at the date of a copy already read', () async {
    for (var i = 0; i < 201; i++) {
      await seedRead(serverDb, 'newer-$i', at: 1000 + i);
    }
    await seedRead(serverDb, 'chat-s');
    final container = await signedIn();
    expect(
      container.read(conversationsProvider).requireValue.map((c) => c.id),
      isNot(contains('chat-s')),
    );
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');
    await serverSaved(serverDb, 'chat-s', 160);
    expect(await storedReadThrough(serverDb, 'chat-s', 160), greaterThan(159));

    // Then a push of this device's that took the server's text, stored in
    // the same second, holds the chat unread at that date.
    await serverDb.chatsDao.holdUnread('chat-s');
    expect(await storedReadThrough(serverDb, 'chat-s', 160), greaterThan(159));
    expect(socket.reads, <String>['chat-s', 'chat-s']);
  });

  test('an on-device chat on screen the list does not hold is read in the '
      'on-device database', () async {
    const id = 'direct-local:tide';
    await directDb.chatsDao.upsertLocalOnlyChat(
      rows: _rows(id, updatedAt: 100, archived: true),
    );
    await directDb.chatsDao.setLastReadAt(id, 100);
    final container = await signedIn();
    container.read(shownChatsProvider.notifier).show('main', id);

    await directDb.chatsDao.upsertLocalOnlyChat(
      rows: _rows(id, updatedAt: 160, archived: true),
    );
    expect(await storedReadThrough(directDb, id, 160), greaterThan(159));
    expect(socket.reads, isEmpty);
  });

  test('no read goes to another account, even for the same chat id', () async {
    await seedRead(serverDb, 'chat-s');
    final otherDb = AppDatabase(NativeDatabase.memory());
    addTearDown(otherDb.close);
    await seedRead(otherDb, 'chat-s');
    final container = await signedIn();
    container.read(shownChatsProvider.notifier).show('main', 'chat-s');

    container.read(_activeDatabaseProvider.notifier).set(otherDb);
    await container.read(conversationsProvider.future);
    await serverSaved(otherDb, 'chat-s', 160);
    await settled(otherDb);
    expect(await storedRead(otherDb, 'chat-s'), 100);
    expect(socket.reads, isEmpty);
  });
}

ChatRows _rows(String id, {required int updatedAt, bool archived = false}) {
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
    archived: archived,
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
