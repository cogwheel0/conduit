import 'dart:async';

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
