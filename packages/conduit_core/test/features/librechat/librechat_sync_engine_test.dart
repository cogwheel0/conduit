import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/features/librechat/services/librechat_sync_engine.dart';
import 'package:conduit_core/sync/backoff.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _root = '00000000-0000-0000-0000-000000000000';

List<Map<String, dynamic>> _turn(String id, String question, String answer) => [
  {
    'messageId': '$id-q',
    'parentMessageId': _root,
    'isCreatedByUser': true,
    'text': question,
    'createdAt': '2026-10-18T10:00:00.000Z',
  },
  {
    'messageId': '$id-a',
    'parentMessageId': '$id-q',
    'isCreatedByUser': false,
    'text': answer,
    'content': [
      {'type': 'text', 'text': answer},
    ],
    'createdAt': '2026-10-18T10:00:05.000Z',
  },
];

void main() {
  const server = LibreChatServer(baseUrl: 'https://chat.example.com');
  late FakeLibreChatServer fake;
  late AppDatabase db;
  late LibreChatSyncEngine engine;
  // The real date: sessions the fake server issues are checked against the
  // real clock, and would lapse against a fixed one.
  var now = DateTime.now().toUtc();

  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  setUp(() async {
    now = DateTime.now().toUtc();
    fake = FakeLibreChatServer(clock: () => now)..addUser();
    db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final auth = LibreChatAuthService(server, adapter: fake);
    addTearDown(auth.close);
    final signedIn =
        await auth.signIn(email: 'dev@example.com', password: 'devpassword')
            as LibreChatSignedIn;
    final client = LibreChatHttpClient(
      server: server,
      adapter: fake,
      session: LibreChatSessionHandle(
        session: signedIn.session,
        store: InMemoryLibreChatSessionStore(),
        renew: auth.renew,
      ),
    );
    addTearDown(client.close);
    engine = LibreChatSyncEngine(
      db: db,
      api: LibreChatApiService(client),
      backoff: Backoff(jitter: () => 0),
    );
  });

  Future<List<String>> storedIds() async => [
    for (final row in await db.select(db.chats).get())
      if (!row.deleted) row.id,
  ];

  test('the fake server lists newest first, whatever the precision', () async {
    fake
      ..addConversation('older', updatedAt: now)
      ..addConversation('newer', updatedAt: now);
    // The same second, one of them written without its fraction.
    fake.conversations['older']!['updatedAt'] = '2026-10-18T10:00:00Z';
    fake.conversations['newer']!['updatedAt'] = '2026-10-18T10:00:00.500Z';
    final page = await engine.api.conversations();
    check(
      page.conversations.map((conversation) => conversation.conversationId),
    ).deepEquals(['newer', 'older']);
  });

  test('pulls every conversation across cursor pages, bodies included', () async {
    for (var i = 0; i < 150; i++) {
      fake.addConversation(
        'c$i',
        title: 'Chat $i',
        updatedAt: now.subtract(Duration(minutes: i)),
        messageList: _turn('c$i', 'Q$i', 'A$i'),
      );
    }
    await engine.pull();
    check(await storedIds()).length.equals(150);
    final row = await db.chatsDao.getChat('c42');
    check(row!.title).equals('Chat 42');
    check(row.bodySynced).isTrue();
    final messages = await db.messagesDao.getForChat('c42');
    check(messages.map((m) => m.content)).unorderedEquals(['Q42', 'A42']);
    check(row.currentMessageId).equals('c42-a');
  });

  test('chats the first sync brings in start read; later ones do not',
      () async {
    fake
      ..addConversation(
        'c1',
        updatedAt: now,
        messageList: _turn('c1', 'Q', 'A'),
      )
      ..addConversation(
        'c2',
        updatedAt: now.subtract(const Duration(hours: 1)),
        messageList: _turn('c2', 'Q', 'A'),
      );
    await engine.pull();
    for (final id in ['c1', 'c2']) {
      final row = (await db.chatsDao.getChat(id))!;
      check(row.lastReadAt).equals(row.updatedAt);
    }

    fake.addConversation(
      'c3',
      updatedAt: now.add(const Duration(minutes: 1)),
      messageList: _turn('c3', 'Q', 'A'),
    );
    await engine.pull();
    check((await db.chatsDao.getChat('c3'))!.lastReadAt).isNull();
  });

  test('chats a first sync cut short brings in later still start read',
      () async {
    fake
      ..addConversation('kept', updatedAt: now)
      ..addConversation(
        'shelved',
        updatedAt: now,
        messageList: _turn('shelved', 'Q', 'A'),
      );
    fake.conversations['shelved']!['isArchived'] = true;
    var archiveDown = true;
    fake.on(
      'GET',
      '/api/messages/shelved',
      (request, match) => archiveDown
          ? FakeLibreChatResponse.json({'message': 'Down'}, statusCode: 503)
          : FakeLibreChatResponse.json(fake.messages['shelved']!),
    );
    check((await engine.pull()).success).isFalse();
    final kept = (await db.chatsDao.getChat('kept'))!;
    check(kept.lastReadAt).equals(kept.updatedAt);

    archiveDown = false;
    check((await engine.pull()).success).isTrue();
    final shelved = (await db.chatsDao.getChat('shelved'))!;
    check(shelved.lastReadAt).equals(shelved.updatedAt);
  });

  test('a later pull fetches only what changed', () async {
    fake
      ..addConversation('old', updatedAt: now.subtract(const Duration(days: 2)))
      ..addConversation('new', updatedAt: now);
    await engine.pull();
    final before = fake.requests
        .where((r) => r.path.startsWith('/api/messages/'))
        .length;
    now = now.add(const Duration(hours: 1));
    fake.addConversation(
      'new',
      title: 'Renamed elsewhere',
      updatedAt: now,
      messageList: _turn('new', 'Q', 'A'),
    );
    await engine.pull();
    final fetched = fake.requests
        .where((r) => r.path.startsWith('/api/messages/'))
        .skip(before)
        .map((r) => r.path);
    check(fetched).deepEquals(['/api/messages/new']);
    check((await db.chatsDao.getChat('new'))!.title).equals('Renamed elsewhere');
  });

  test('pins and archiving made elsewhere arrive without an update', () async {
    fake
      ..addConversation('a', updatedAt: now)
      ..addConversation('b', updatedAt: now.subtract(const Duration(hours: 1)));
    await engine.pull();
    // LibreChat changes neither conversation's updatedAt for these.
    fake.conversations['a']!['pinned'] = true;
    fake.conversations['b']!['isArchived'] = true;
    await engine.pull(forceReconcile: true);
    check((await db.chatsDao.getChat('a'))!.pinned).isTrue();
    check((await db.chatsDao.getChat('b'))!.archived).isTrue();
  });

  test('a conversation unarchived between the two lists stays', () async {
    fake
      ..addConversation('moving', updatedAt: now)
      ..addConversation('other', updatedAt: now);
    fake.conversations['moving']!['isArchived'] = true;
    await engine.pull();
    check(await storedIds()).contains('moving');

    // Unarchived after the active list was read, before the archived one:
    // in neither. (The pinned lists read before them do not count.)
    fake.onRequest = (request) {
      final query = request.uri.queryParameters;
      if (request.path == '/api/convos' &&
          query['isArchived'] == 'true' &&
          query['pinned'] != 'true') {
        fake.conversations['moving']!['isArchived'] = false;
      }
    };
    await engine.pull(forceReconcile: true);
    check(await storedIds()).contains('moving');
  });

  test('a conversation deleted elsewhere goes; a dirty one stays', () async {
    fake
      ..addConversation('keep', updatedAt: now)
      ..addConversation('gone', updatedAt: now)
      ..addConversation('edited', updatedAt: now);
    await engine.pull();
    fake.conversations
      ..remove('gone')
      ..remove('edited');
    await db.chatsDao.updateEnvelope('edited', title: const Value('Local'));
    await (db.update(db.chats)..where((t) => t.id.equals('edited'))).write(
      const ChatsCompanion(dirty: Value(true)),
    );
    await engine.pull(forceReconcile: true);
    check(await storedIds()).unorderedEquals(['keep', 'edited']);
  });

  test('an empty server list never wipes a populated cache', () async {
    for (var i = 0; i < 5; i++) {
      fake.addConversation('c$i', updatedAt: now);
    }
    await engine.pull();
    fake.conversations.clear();
    await engine.pull(forceReconcile: true);
    check(await storedIds()).length.equals(5);
  });

  test('offline renames, pins and archives push as LibreChat calls', () async {
    fake.addConversation('c1', title: 'Old', updatedAt: now);
    await engine.pull();
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('New title'),
      pinned: const Value(true),
      enqueue: true,
    );
    // A pull while the edit waits does not undo it.
    await engine.pull();
    check((await db.chatsDao.getChat('c1'))!.title).equals('New title');

    await engine.drain();
    check(fake.conversations['c1']!['title']).equals('New title');
    check(fake.conversations['c1']!['pinned']).equals(true);
    final paths = fake.requests.map((r) => '${r.method} ${r.path}').toList();
    check(paths).contains('POST /api/convos/update');
    check(paths).contains('POST /api/convos/pin');
    check(paths).not((it) => it.contains('POST /api/convos/archive'));
    final row = (await db.chatsDao.getChat('c1'))!;
    check(row.dirty).isFalse();

    // The server's answer agrees, so the next pull leaves it alone.
    await engine.pull(forceReconcile: true);
    check((await db.chatsDao.getChat('c1'))!.pinned).isTrue();
  });

  test('a chat with a rename still queued takes the server\'s messages and '
      'keeps its title', () async {
    fake.addConversation(
      'c1',
      title: 'Old',
      updatedAt: now,
      messageList: _turn('c1', 'Q', 'A'),
    );
    await engine.pull();
    // Answered further elsewhere, while a rename here waits to go out.
    fake.addConversation(
      'c1',
      title: 'Old',
      updatedAt: now.add(const Duration(minutes: 1)),
      messageList: [
        ..._turn('c1', 'Q', 'A'),
        ..._turn('c1b', 'Q2', 'A2').map(
          (message) => message['parentMessageId'] == _root
              ? {...message, 'parentMessageId': 'c1-a'}
              : message,
        ),
      ],
    );
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('New title'),
      enqueue: true,
    );

    check(await engine.pullChat('c1')).isTrue();
    check(await db.messagesDao.getForChat('c1')).length.equals(4);
    final row = (await db.chatsDao.getChat('c1'))!;
    check(row.title).equals('New title');
    check(row.dirty).isTrue();

    await engine.drain();
    check(fake.conversations['c1']!['title']).equals('New title');
  });

  test('a pin still queued keeps a rename made elsewhere', () async {
    fake.addConversation('c1', title: 'Old', updatedAt: now);
    await engine.pull();
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      pinned: const Value(true),
      enqueue: true,
    );
    // Renamed in LibreChat's web app while the pin waits to go out.
    fake.addConversation(
      'c1',
      title: 'Renamed elsewhere',
      updatedAt: now.add(const Duration(minutes: 1)),
    );

    check(await engine.pullChat('c1')).isTrue();
    final row = (await db.chatsDao.getChat('c1'))!;
    check(row.title).equals('Renamed elsewhere');
    check(row.pinned).isTrue();

    await engine.drain();
    check(fake.conversations['c1']!['title']).equals('Renamed elsewhere');
    check(fake.conversations['c1']!['pinned']).equals(true);
  });

  test('a push cut short records what reached the server', () async {
    fake.addConversation('c1', title: 'A', updatedAt: now);
    await engine.pull();
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('B'),
      pinned: const Value(true),
      enqueue: true,
    );
    // The rename goes through; the pin after it does not.
    fake.on(
      'POST',
      '/api/convos/pin',
      (request, match) =>
          FakeLibreChatResponse.json({'message': 'Down'}, statusCode: 503),
    );
    await engine.drain();
    check(fake.conversations['c1']!['title']).equals('B');

    // Renamed back before the retry: the server has B, so A is sent.
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('A'),
      enqueue: true,
    );
    // The retry is due now, rather than after its backoff.
    await db.outboxDao.resetBackoffForPending(
      nowEpochSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await engine.drain();
    check(fake.conversations['c1']!['title']).equals('A');
    check((await db.chatsDao.getChat('c1'))!.dirty).isTrue();
  });

  test('a pull while a push is out keeps what the push recorded', () async {
    fake.addConversation('c1', title: 'A', updatedAt: now);
    await engine.pull();
    // The chat as the server had it before the rename below.
    final before = Map<String, dynamic>.from(fake.conversations['c1']!);
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('B'),
      pinned: const Value(true),
      enqueue: true,
    );
    var pinDown = true;
    fake.on('POST', '/api/convos/pin', (request, match) async {
      if (!pinDown) {
        final arg = (request.data as Map)['arg'] as Map;
        fake.conversations['c1']!['pinned'] = arg['pinned'];
        return FakeLibreChatResponse.json(fake.conversations['c1']!);
      }
      pinDown = false;
      // The rename is through. The user renames back, and a pull that read
      // the chat before the rename landed stores it, while the push is out.
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('A'),
        enqueue: true,
      );
      fake.on(
        'GET',
        '/api/convos/c1',
        (request, match) => FakeLibreChatResponse.json(before),
      );
      await engine.pullChat('c1');
      return FakeLibreChatResponse.json({'message': 'Down'}, statusCode: 503);
    });
    await engine.drain();
    check(fake.conversations['c1']!['title']).equals('B');

    await db.outboxDao.resetBackoffForPending(
      nowEpochSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await engine.drain();
    check(fake.conversations['c1']!['title']).equals('A');
    check(fake.conversations['c1']!['pinned']).equals(true);
  });

  test('a push waits for a pull to put the local edit back', () async {
    fake.addConversation('c1', title: 'Old', updatedAt: now);
    await engine.pull();
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('New'),
      enqueue: true,
    );
    Future<void> write(String title, {required bool dirty}) =>
        (db.update(db.chats)..where((t) => t.id.equals('c1'))).write(
          ChatsCompanion(title: Value(title), dirty: Value(dirty)),
        );
    late Future<void> drained;
    // As a pull storing the chat does under its lock: the server's fields
    // first, then the local edit put back.
    await engine.locks.runExclusive('c1', () async {
      await write('Old', dirty: false);
      drained = engine.drain();
      await pumpEventQueue();
      await write('New', dirty: true);
    });
    await drained;
    check(fake.conversations['c1']!['title']).equals('New');
    check((await db.chatsDao.getChat('c1'))!.dirty).isFalse();
  });

  test('a chat archived elsewhere behind the archive watermark arrives '
      'whole', () async {
    fake
      ..addConversation(
        'moved',
        updatedAt: now.subtract(const Duration(days: 1)),
        messageList: _turn('moved', 'Q', 'A'),
      )
      ..addConversation('archived', updatedAt: now);
    fake.conversations['archived']!['isArchived'] = true;
    await engine.pull();

    // Messages added, then archived: its updatedAt stays behind the newer
    // archived chat's, so the archived list's watermark passes it by.
    fake.addConversation(
      'moved',
      updatedAt: now.subtract(const Duration(hours: 12)),
      messageList: [
        ..._turn('moved', 'Q', 'A'),
        ..._turn('moved2', 'Q2', 'A2').map(
          (message) => message['parentMessageId'] == _root
              ? {...message, 'parentMessageId': 'moved-a'}
              : message,
        ),
      ],
    );
    fake.conversations['moved']!['isArchived'] = true;
    await engine.pull(forceReconcile: true);

    final row = (await db.chatsDao.getChat('moved'))!;
    check(row.archived).isTrue();
    check(await db.messagesDao.getForChat('moved')).length.equals(4);
  });

  test('a pull that misses the archive does not report success', () async {
    fake.addConversation('c1', updatedAt: now);
    fake.on('GET', '/api/convos', (request, match) {
      final query = request.uri.queryParameters;
      if (query['isArchived'] == 'true') {
        return FakeLibreChatResponse.json({'message': 'Down'}, statusCode: 503);
      }
      return FakeLibreChatResponse.json({
        'conversations': [
          for (final conversation in fake.conversations.values)
            if (query['pinned'] != 'true' || conversation['pinned'] == true)
              conversation,
        ],
        'nextCursor': null,
      });
    });

    final result = await engine.pull();
    check(result.success).isFalse();
    check(await storedIds()).deepEquals(['c1']);
  });

  test('a local delete pushes and purges', () async {
    fake.addConversation('c1', updatedAt: now);
    await engine.pull();
    await db.chatsDao.tombstoneWithOutbox('c1');
    await engine.drain();
    check(fake.conversations).isEmpty();
    check(await db.chatsDao.getChat('c1')).isNull();
  });

  test('a chat fetched before its delete went through stays deleted',
      () async {
    fake.addConversation(
      'c1',
      updatedAt: now,
      messageList: _turn('c1', 'Q', 'A'),
    );
    await engine.pull();
    // Changed elsewhere, so the next pull fetches its messages, and that
    // fetch is answered only once the delete is through.
    now = now.add(const Duration(hours: 1));
    fake.addConversation(
      'c1',
      updatedAt: now,
      messageList: _turn('c1', 'Q', 'A'),
    );
    final messages = fake.messages['c1']!;
    final fetching = Completer<void>();
    final answer = Completer<void>();
    fake.on('GET', '/api/messages/c1', (request, match) async {
      if (!fetching.isCompleted) fetching.complete();
      await answer.future;
      return FakeLibreChatResponse.json(messages);
    });
    final pulling = engine.pull();
    await fetching.future;

    await db.chatsDao.tombstoneWithOutbox('c1');
    await engine.drain();
    check(await db.chatsDao.getChat('c1')).isNull();

    answer.complete();
    await pulling;
    check(await db.chatsDao.getChat('c1')).isNull();
  });

  test('a chat another engine on the database deleted stays deleted',
      () async {
    fake.addConversation(
      'c1',
      updatedAt: now,
      messageList: _turn('c1', 'Q', 'A'),
    );
    await engine.pull();
    now = now.add(const Duration(hours: 1));
    fake.addConversation(
      'c1',
      updatedAt: now,
      messageList: _turn('c1', 'Q', 'A'),
    );
    final messages = fake.messages['c1']!;
    final fetching = Completer<void>();
    final answer = Completer<void>();
    fake.on('GET', '/api/messages/c1', (request, match) async {
      if (!fetching.isCompleted) fetching.complete();
      await answer.future;
      return FakeLibreChatResponse.json(messages);
    });
    final pulling = engine.pull();
    await fetching.future;

    // A quick return to the account: a new engine deletes the chat while the
    // old one is still pulling it.
    final next = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      backoff: Backoff(jitter: () => 0),
    );
    await db.chatsDao.tombstoneWithOutbox('c1');
    await next.drain();
    check(await db.chatsDao.getChat('c1')).isNull();

    answer.complete();
    await pulling;
    check(await db.chatsDao.getChat('c1')).isNull();
  });

  test('a copy read before a push finished does not undo it', () async {
    fake.addConversation(
      'c1',
      title: 'Old',
      updatedAt: now,
      messageList: _turn('c1', 'Q', 'A'),
    );
    await engine.pull();
    now = now.add(const Duration(hours: 1));
    fake.addConversation(
      'c1',
      title: 'Old',
      updatedAt: now,
      messageList: _turn('c1', 'Q', 'A'),
    );
    final messages = fake.messages['c1']!;
    final fetching = Completer<void>();
    final answer = Completer<void>();
    fake.on('GET', '/api/messages/c1', (request, match) async {
      if (!fetching.isCompleted) {
        fetching.complete();
        await answer.future;
      }
      return FakeLibreChatResponse.json(messages);
    });
    final pulling = engine.pull();
    await fetching.future;

    // Renamed here and pushed while the pull holds the copy it listed.
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('New'),
      enqueue: true,
    );
    await engine.drain();
    check(fake.conversations['c1']!['title']).equals('New');

    answer.complete();
    await pulling;
    check((await db.chatsDao.getChat('c1'))!.title).equals('New');
  });

  test('a chat archived here arrives whole with what the server '
      'gained', () async {
    fake
      ..addConversation(
        'moved',
        updatedAt: now.subtract(const Duration(days: 1)),
        messageList: _turn('moved', 'Q', 'A'),
      )
      ..addConversation('archived', updatedAt: now, archived: true);
    await engine.pull();

    // Messages added elsewhere, then archived here before a pull saw them:
    // its updatedAt stays behind the newer archived chat's, so the archived
    // list's watermark passes it by.
    fake.addConversation(
      'moved',
      updatedAt: now.subtract(const Duration(hours: 12)),
      messageList: [
        ..._turn('moved', 'Q', 'A'),
        ..._turn('moved2', 'Q2', 'A2').map(
          (message) => message['parentMessageId'] == _root
              ? {...message, 'parentMessageId': 'moved-a'}
              : message,
        ),
      ],
    );
    await db.chatsDao.updateEnvelopeWithOutbox(
      'moved',
      archived: const Value(true),
      enqueue: true,
    );
    await engine.drain();
    check(fake.conversations['moved']!['isArchived']).equals(true);

    await engine.pull(forceReconcile: true);
    final row = (await db.chatsDao.getChat('moved'))!;
    check(row.archived).isTrue();
    check(await db.messagesDao.getForChat('moved')).length.equals(4);
  });

  test('a chat moved between the lists during a first sync arrives at the '
      'next full pass', () async {
    fake
      ..addConversation(
        'moving',
        updatedAt: now.subtract(const Duration(days: 1)),
        archived: true,
        messageList: _turn('moving', 'Q', 'A'),
      )
      ..addConversation('active', updatedAt: now)
      ..addConversation('archived', updatedAt: now, archived: true);
    // Unarchived after the active list was read, before the archived one:
    // neither pass stores it. (The pinned lists read before them do not
    // count.)
    fake.onRequest = (request) {
      final query = request.uri.queryParameters;
      if (request.path == '/api/convos' &&
          query['isArchived'] == 'true' &&
          query['pinned'] != 'true') {
        fake.conversations['moving']!['isArchived'] = false;
      }
    };
    await engine.pull();
    check(await db.chatsDao.getChat('moving')).isNull();
    // The archived pass stores what the full pass found unstored; it is
    // not fetched a second time.
    check(
      fake.requests.where((r) => r.path == '/api/messages/archived'),
    ).length.equals(1);

    // Behind both watermarks now; the next full pass finds it unstored.
    await engine.pull(forceReconcile: true);
    final row = (await db.chatsDao.getChat('moving'))!;
    check(row.archived).isFalse();
    check(await db.messagesDao.getForChat('moving')).length.equals(2);
  });

  test('a generating conversation is not overwritten', () async {
    final generating = <String>{'c1'};
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      isGenerating: generating.contains,
      backoff: Backoff(jitter: () => 0),
    );
    fake.addConversation('c1', updatedAt: now);
    await engine.pull();
    check(await db.chatsDao.getChat('c1')).isNull();
    generating.clear();
    check(await engine.pullChat('c1')).isTrue();
    check(await db.chatsDao.getChat('c1')).isNotNull();
    check(await engine.pullChat('missing')).isFalse();
  });

  test('a conversation passed over while it generated arrives later', () async {
    final generating = <String>{'c1'};
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      isGenerating: generating.contains,
      backoff: Backoff(jitter: () => 0),
    );
    // c2 is newer by more than the pull overlap, so the watermark passes c1.
    fake
      ..addConversation(
        'c1',
        updatedAt: now.subtract(const Duration(hours: 1)),
        messageList: _turn('c1', 'Q', 'A'),
      )
      ..addConversation('c2', updatedAt: now);
    await engine.pull();
    check(await db.chatsDao.getChat('c1')).isNull();

    generating.clear();
    await engine.pull();
    check(await db.chatsDao.getChat('c1')).isNotNull();
    check(await db.messagesDao.getForChat('c1')).length.equals(2);
  });

  test('a conversation passed over is saved for later before the watermark '
      'moves past it', () async {
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      isGenerating: {'c1'}.contains,
      backoff: Backoff(jitter: () => 0),
    );
    fake
      ..addConversation(
        'c1',
        updatedAt: now.subtract(const Duration(hours: 1)),
        messageList: _turn('c1', 'Q', 'A'),
      )
      ..addConversation('c2', updatedAt: now);
    // Read as the pull moves on from the active list, its watermark written:
    // what the app would find if it were killed there.
    Future<String?>? watermark;
    Future<String?>? deferred;
    fake.onRequest = (request) {
      if (request.uri.queryParameters['pinned'] != 'true') return;
      watermark ??= db.syncMetaDao.getValue(LibreChatSyncEngine.watermarkKey);
      deferred ??= db.syncMetaDao.getValue(LibreChatSyncEngine.deferredKey);
    };
    await engine.pull();
    check(await watermark).isNotNull();
    check(await deferred).isNotNull().contains('"c1"');
  });

  test('a passed-over conversation whose fetch fails in any way is kept',
      () async {
    var stage = 0;
    var calls = 0;
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      backoff: Backoff(jitter: () => 0),
      isGenerating: (id) {
        if (id != 'c1' || stage == 2) return false;
        if (stage == 0) return true;
        // Done generating when the pull picks it up; failing as it stores.
        if (++calls == 2) throw StateError('local failure');
        return false;
      },
    );
    fake
      ..addConversation(
        'c1',
        updatedAt: now.subtract(const Duration(hours: 1)),
        messageList: _turn('c1', 'Q', 'A'),
      )
      ..addConversation('c2', updatedAt: now);
    await engine.pull();
    check(await db.chatsDao.getChat('c1')).isNull();

    stage = 1;
    await check(engine.pull()).throws<StateError>();

    stage = 2;
    await engine.pull();
    check(await db.chatsDao.getChat('c1')).isNotNull();
  });

  test('a pull or drain that cannot hold the database lets the next run',
      () async {
    var refuse = true;
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      backoff: Backoff(jitter: () => 0),
      holdDatabase: () {
        if (refuse) throw StateError('closing');
        return () async {};
      },
    );
    fake.addConversation('c1', updatedAt: now);
    await check(engine.pull()).throws<StateError>();
    await check(engine.drain()).throws<StateError>();

    refuse = false;
    check((await engine.pull()).success).isTrue();
    await engine.drain();
    check(await storedIds()).deepEquals(['c1']);
  });

  test('a conversation passed over by a pull cut short is kept for later',
      () async {
    final generating = <String>{'c1'};
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      isGenerating: generating.contains,
      backoff: Backoff(jitter: () => 0),
    );
    fake
      ..addConversation(
        'c1',
        updatedAt: now.subtract(const Duration(hours: 1)),
        messageList: _turn('c1', 'Q', 'A'),
      )
      ..addConversation('c2', updatedAt: now);
    // The account is left while the pull runs: it stops after the first
    // pass, past c1.
    fake.onRequest = (request) {
      if (request.path == '/api/convos' &&
          request.uri.queryParameters['pinned'] == 'true') {
        engine.close();
      }
    };
    await engine.pull();
    check(
      await db.syncMetaDao.getValue(LibreChatSyncEngine.deferredKey),
    ).isNotNull().contains('c1');
  });

  test('a chat archived here is still fetched after a restart before the '
      'next pull', () async {
    // On disk, so the restart below opens it afresh.
    final dir = await Directory.systemTemp.createTemp('librechat-sync');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/chats.sqlite');
    db = AppDatabase(NativeDatabase(file));
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      backoff: Backoff(jitter: () => 0),
    );
    fake
      ..addConversation(
        'moved',
        updatedAt: now.subtract(const Duration(days: 1)),
        messageList: _turn('moved', 'Q', 'A'),
      )
      ..addConversation('archived', updatedAt: now, archived: true);
    await engine.pull();
    // Messages added elsewhere, then archived here: the archived list's
    // watermark passes it by, so only the push's follow-up fetches them.
    fake.addConversation(
      'moved',
      updatedAt: now.subtract(const Duration(hours: 12)),
      messageList: [
        ..._turn('moved', 'Q', 'A'),
        ..._turn('moved2', 'Q2', 'A2').map(
          (message) => message['parentMessageId'] == _root
              ? {...message, 'parentMessageId': 'moved-a'}
              : message,
        ),
      ],
    );
    await db.chatsDao.updateEnvelopeWithOutbox(
      'moved',
      archived: const Value(true),
      enqueue: true,
    );
    await engine.drain();

    // The app restarts before another pull.
    await db.close();
    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      backoff: Backoff(jitter: () => 0),
    );
    await engine.pull(forceReconcile: true);
    check(await db.messagesDao.getForChat('moved')).length.equals(4);
  });

  test('an engine handed a database another still works in keeps the chats '
      'it passed over', () async {
    fake
      ..addConversation(
        'moved',
        updatedAt: now.subtract(const Duration(days: 1)),
        messageList: _turn('moved', 'Q', 'A'),
      )
      ..addConversation('archived', updatedAt: now, archived: true);
    await engine.pull();
    // A quick return to the account: a new engine on the same database,
    // which has read the saved list of passed-over chats already.
    final back = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      backoff: Backoff(jitter: () => 0),
    );
    await back.pull();
    // The departing engine archives a chat changed elsewhere, which only
    // its follow-up fetch brings in.
    fake.addConversation(
      'moved',
      updatedAt: now.subtract(const Duration(hours: 12)),
      messageList: [
        ..._turn('moved', 'Q', 'A'),
        ..._turn('moved2', 'Q2', 'A2').map(
          (message) => message['parentMessageId'] == _root
              ? {...message, 'parentMessageId': 'moved-a'}
              : message,
        ),
      ],
    );
    await db.chatsDao.updateEnvelopeWithOutbox(
      'moved',
      archived: const Value(true),
      enqueue: true,
    );
    await engine.drain();
    engine.close();

    await back.pull(forceReconcile: true);
    check(await db.messagesDao.getForChat('moved')).length.equals(4);
  });

  test('a passed-over conversation that still cannot be fetched fails the '
      'pull', () async {
    final generating = <String>{'c1'};
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      isGenerating: generating.contains,
      backoff: Backoff(jitter: () => 0),
    );
    fake
      ..addConversation(
        'c1',
        updatedAt: now.subtract(const Duration(hours: 1)),
        messageList: _turn('c1', 'Q', 'A'),
      )
      ..addConversation('c2', updatedAt: now);
    check((await engine.pull()).success).isTrue();

    generating.clear();
    fake.on(
      'GET',
      '/api/convos/c1',
      (request, match) =>
          FakeLibreChatResponse.json({'message': 'Down'}, statusCode: 503),
    );
    final result = await engine.pull();
    check(result.success).isFalse();
    check(result.failedFetches).equals(1);
  });

  test('a pull holds its database open until it is done', () async {
    var held = 0;
    var released = 0;
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      holdDatabase: () {
        held++;
        return () async => released++;
      },
      backoff: Backoff(jitter: () => 0),
    );
    fake.addConversation('c1', updatedAt: now);
    await engine.pull();
    check(held).equals(1);
    check(released).equals(1);
  });

  test('an edit queued while a drain lets its database go still drains',
      () async {
    fake.addConversation('c1', title: 'Old', updatedAt: now);
    await engine.pull();
    final releasing = Completer<void>();
    final letGo = Completer<void>();
    var holds = 0;
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      holdDatabase: () {
        // Only the first drain's release is held up.
        final first = holds++ == 0;
        return () async {
          if (!first) return;
          releasing.complete();
          await letGo.future;
        };
      },
      backoff: Backoff(jitter: () => 0),
    );

    final first = engine.drain();
    await releasing.future;
    // That drain's loop is over: the edit arrives as its release yields.
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('New title'),
      enqueue: true,
    );
    final second = engine.drain();
    letGo.complete();
    await Future.wait([first, second]);

    check(fake.conversations['c1']!['title']).equals('New title');
  });

  test('an engine handed a database another still drains waits for it',
      () async {
    fake.addConversation('c1', title: 'Old', updatedAt: now);
    await engine.pull();
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('New title'),
      enqueue: true,
    );
    final pushing = Completer<void>();
    final answer = Completer<void>();
    var renames = 0;
    fake.on('POST', '/api/convos/update', (request, match) async {
      renames++;
      if (!pushing.isCompleted) pushing.complete();
      await answer.future;
      final arg = (request.data as Map)['arg'] as Map;
      final conversation = fake.conversations[arg['conversationId']]!;
      conversation['title'] = arg['title'];
      return FakeLibreChatResponse.json(conversation);
    });
    final leaving = engine.drain();
    await pushing.future;
    // The account is left and returned to while the rename is out: a new
    // engine gets the same database.
    engine.close();
    final back = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      backoff: Backoff(jitter: () => 0),
    );
    final draining = back.drain();
    await pumpEventQueue(times: 200);
    // The rename still out is not taken back and sent again.
    check(renames).equals(1);
    check(
      (await db.select(db.outboxOps).get()).single.status,
    ).equals(OutboxStatus.inFlight);

    answer.complete();
    await Future.wait([leaving, draining]);
    check(renames).equals(1);
    check(await db.select(db.outboxOps).get()).isEmpty();
    check(fake.conversations['c1']!['title']).equals('New title');
  });

  test('archived conversations arrive with their messages', () async {
    fake.addConversation(
      'old',
      updatedAt: now,
      archived: true,
      pinned: true,
      messageList: _turn('old', 'Q', 'A'),
    );
    await engine.pull(forceReconcile: true);
    final row = (await db.chatsDao.getChat('old'))!;
    check(row.archived).isTrue();
    // Still pinned on the server, though only the archived list says so.
    check(row.pinned).isTrue();
    check(row.bodySynced).isTrue();
    check(await db.messagesDao.getForChat('old')).length.equals(2);
  });

  test('a refused edit stays while the server\'s messages arrive', () async {
    fake.addConversation(
      'c1',
      title: 'Server',
      updatedAt: now,
      messageList: _turn('c1', 'Q', 'A'),
    );
    await engine.pull();
    await db.chatsDao.updateEnvelopeWithOutbox(
      'c1',
      title: const Value('Mine'),
      enqueue: true,
    );
    // The server refused the rename for good: the op is parked.
    await (db.update(db.outboxOps)..where((t) => t.chatId.equals('c1')))
        .write(const OutboxOpsCompanion(status: Value('failed')));

    now = now.add(const Duration(hours: 1));
    fake.addConversation(
      'c1',
      title: 'Server',
      updatedAt: now,
      messageList: [
        ..._turn('c1', 'Q', 'A'),
        ..._turn('c1b', 'Q2', 'A2').map(
          (message) => message['parentMessageId'] == _root
              ? {...message, 'parentMessageId': 'c1-a'}
              : message,
        ),
      ],
    );
    await engine.pull();
    final row = (await db.chatsDao.getChat('c1'))!;
    check(row.title).equals('Mine');
    check(row.dirty).isTrue();
    check(await db.messagesDao.getForChat('c1')).length.equals(4);
  });

  test('a forced reconcile asked for mid-pull still runs', () async {
    engine = LibreChatSyncEngine(
      db: db,
      api: engine.api,
      backoff: Backoff(jitter: () => 0),
      reconcileInterval: const Duration(days: 1),
    );
    fake
      ..addConversation('keep', updatedAt: now)
      ..addConversation('gone', updatedAt: now);
    await engine.pull();
    fake.conversations.remove('gone');

    final first = engine.pull();
    final forced = engine.pull(forceReconcile: true);
    await Future.wait([first, forced]);
    check(await db.chatsDao.getChat('gone')).isNull();
    check(await db.chatsDao.getChat('keep')).isNotNull();
  });

  test('an id list cut short deletes nothing', () async {
    fake
      ..addConversation('a', updatedAt: now)
      ..addConversation('b', updatedAt: now);
    await engine.pull();
    // A list that never ends: every page names one chat and a next page.
    fake.on(
      'GET',
      '/api/convos',
      (request, match) => FakeLibreChatResponse.json({
        'conversations': [fake.conversations['a']],
        'nextCursor': 'more',
      }),
    );
    await engine.pull(forceReconcile: true);
    check(await db.chatsDao.getChat('b')).isNotNull();
  });

  test('a queued send without a runner is kept, not counted sent', () async {
    fake.addConversation('c1', updatedAt: now);
    await engine.pull();
    await db.outboxDao.enqueue(
      kind: OutboxKind.requestCompletion,
      chatId: 'c1',
      payload: const {
        'assistantMessageId': 'a1',
        'model': 'm',
        'toolIds': <String>[],
      },
    );
    await engine.drain();
    final ops = await db.select(db.outboxOps).get();
    check(ops).length.equals(1);
    check(ops.single.attempts).equals(1);
  });
}
