import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/clock.dart';
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:conduit_core/sync/outbox_drainer.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/push_sync.dart';
import 'package:conduit_core/sync/sync_api_client.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

import 'package:conduit_core/testing.dart';

class FakeSyncClock implements SyncClock {
  int now = 0;
  @override
  int nowEpochSeconds() => now;
}

class _DeleteAfterArchiveToggleClient extends FakeSyncApiClient {
  _DeleteAfterArchiveToggleClient(super.server);

  @override
  Future<Map<String, dynamic>?> toggleArchive(String id) async {
    final response = await super.toggleArchive(id);
    server.deleteChat(id);
    return response;
  }
}

/// Reads the chat when asked, then holds the copy until [release]: a pull
/// whose read lands before a push and whose merge comes after it.
class _HeldChatReadClient extends FakeSyncApiClient {
  _HeldChatReadClient(
    super.server, {
    required this.read,
    required this.release,
    this.envelope = const {},
  });

  final Completer<void> read;
  final Completer<void> release;

  /// Laid over each copy as it is read: what Open WebUI keeps beside the
  /// chat without moving its `updated_at` (tags, a share link), which the
  /// fake server does not hold.
  Map<String, dynamic> envelope;

  /// How many times the chat was read.
  int reads = 0;

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    reads++;
    final copy = await super.getChatRaw(id);
    final beside = envelope;
    if (!read.isCompleted) read.complete();
    await release.future;
    return copy == null ? null : {...copy, ...beside};
  }
}

/// Fails the pin that follows an update: the update has reached the server,
/// and the push has not finished.
class _PinFailsClient extends FakeSyncApiClient {
  _PinFailsClient(super.server);

  @override
  Future<Map<String, dynamic>?> togglePin(String id) async =>
      throw StateError('connection reset while pinning $id');
}

/// Lets a create reach the server, then holds its answer until [release]:
/// the chat is on the server, and still `local:` here.
class _HeldCreateClient extends FakeSyncApiClient {
  _HeldCreateClient(
    super.server, {
    required this.created,
    required this.release,
  });

  final Completer<String> created;
  final Completer<void> release;

  @override
  Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> chatBlob, {
    String? folderId,
  }) async {
    final response = await super.createChat(chatBlob, folderId: folderId);
    created.complete(response['id'] as String);
    await release.future;
    return response;
  }
}

/// Runs [afterRead] after each read of a chat, before the copy is handed
/// back, and lays [envelope] over the copy (see [_HeldChatReadClient]).
class _ReadHookClient extends FakeSyncApiClient {
  _ReadHookClient(super.server);

  Map<String, dynamic> envelope = const {};
  Future<void> Function()? afterRead;

  @override
  Future<Map<String, dynamic>?> getChatRaw(String id) async {
    final copy = await super.getChatRaw(id);
    await afterRead?.call();
    return copy == null ? null : {...copy, ...envelope};
  }
}

class _RevertArchiveToggleClient extends FakeSyncApiClient {
  _RevertArchiveToggleClient(super.server);

  @override
  Future<Map<String, dynamic>?> toggleArchive(String id) async {
    final response = await super.toggleArchive(id);
    await super.toggleArchive(id);
    return response;
  }
}

class _RevertPinToggleClient extends FakeSyncApiClient {
  _RevertPinToggleClient(super.server);

  @override
  Future<Map<String, dynamic>?> togglePin(String id) async {
    final response = await super.togglePin(id);
    await super.togglePin(id);
    return response;
  }
}

class _DeleteSourceAfterCreateClient extends FakeSyncApiClient {
  _DeleteSourceAfterCreateClient(
    super.server, {
    required this.db,
    required this.localId,
  });

  final AppDatabase db;
  final String localId;

  @override
  Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> chatBlob, {
    String? folderId,
  }) async {
    final response = await super.createChat(chatBlob, folderId: folderId);
    // Reproduce a lifecycle purge after the server accepted the POST but
    // before PushSync can commit the local -> server id remap.
    await db.chatsDao.deleteLocalOnlyChat(localId);
    return response;
  }
}

/// Seeds a local (`local:`) chat + messages directly, dirty by default.
Future<void> seedLocalChat(
  AppDatabase db, {
  required String id,
  int messageCount = 2,
  String? folderId,
  bool pinned = false,
  bool archived = false,
  bool dirty = true,
  bool bodySynced = true,
  Map<String, dynamic>? extraBlobKeys,
}) async {
  await db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: id,
          title: 'Title $id',
          folderId: Value(folderId),
          pinned: Value(pinned),
          archived: Value(archived),
          currentMessageId: Value('$id-m$messageCount'),
          createdAt: 100,
          updatedAt: 200,
          dirty: Value(dirty),
          bodySynced: Value(bodySynced),
          rawExtra: Value(jsonEncode(extraBlobKeys ?? <String, dynamic>{})),
          blobMeta: Value(
            jsonEncode(<String, dynamic>{
              'v': 1,
              'blobHadTitle': true,
              'blobTitleValue': 'Title $id',
              'blobHadHistory': true,
              'historyHadMessages': true,
              'historyHadCurrentId': true,
              'historyExtra': <String, dynamic>{},
              'unmappableMessages': <String, dynamic>{},
            }),
          ),
        ),
      );
  for (var i = 1; i <= messageCount; i++) {
    final role = i.isOdd ? 'user' : 'assistant';
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: '$id-m$i',
            chatId: id,
            parentId: Value(i == 1 ? null : '$id-m${i - 1}'),
            role: role,
            content: 'message $i of $id',
            createdAt: 1000 + i,
            orderIndex: i - 1,
            payload: jsonEncode(<String, dynamic>{
              'id': '$id-m$i',
              'parentId': i == 1 ? null : '$id-m${i - 1}',
              'childrenIds': <String>[],
              'role': role,
              'content': 'message $i of $id',
              'timestamp': 1000 + i,
            }),
            dirty: Value(dirty),
          ),
        );
  }
}

Future<void> seedParkedFolderOp(
  AppDatabase db,
  String folderId, {
  OutboxKind kind = OutboxKind.folderUpsert,
}) {
  return db
      .into(db.outboxOps)
      .insert(
        OutboxOpsCompanion.insert(
          kind: kind.name,
          chatId: Value(folderId),
          status: const Value(OutboxStatus.failed),
          attempts: const Value(5),
          lastError: const Value('parked folder op'),
        ),
      );
}

Future<List<OutboxOp>> outboxOpsForChat(AppDatabase db, String chatId) {
  return (db.select(db.outboxOps)..where((t) => t.chatId.equals(chatId))).get();
}

void main() {
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late AppDatabase db;
  late ConversationLocks chatLocks;
  late FolderLocks folderLocks;
  late IdRemapper remapper;
  late FakeSyncClock clock;
  late PushSync push;

  setUp(() {
    server = FakeOpenWebUiServer(nowEpochSeconds: () => 7000);
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    chatLocks = ConversationLocks();
    folderLocks = FolderLocks();
    remapper = IdRemapper(db);
    clock = FakeSyncClock();
    push = PushSync(
      client: client,
      db: db,
      chatLocks: chatLocks,
      folderLocks: folderLocks,
      clock: clock,
      remapper: remapper,
    );
  });

  tearDown(() async {
    await remapper.dispose();
    await db.close();
  });

  group('pushCreateChat', () {
    test('creates server chat, remaps local id, clears dirty', () async {
      const localId = 'local:new';
      await seedLocalChat(db, id: localId, messageCount: 2);

      final serverId = await push.pushCreateChat(localId);

      check(serverId).isNotNull();
      check(client.createChatCalls).equals(1);

      // Local row gone, server row present with body.
      check(await db.chatsDao.getChat(localId)).isNull();
      final chat = await db.chatsDao.getChat(serverId!);
      check(chat).isNotNull();
      check(chat!.createdAt).equals(7000);
      check(chat.updatedAt).equals(7000);
      check(chat.serverUpdatedAt).equals(7000);
      check(chat.dirty).isFalse();

      // Messages repointed + dirty cleared.
      final msgs = await db.messagesDao.getForChat(serverId);
      check(msgs.length).equals(2);
      check(msgs.every((m) => !m.dirty)).isTrue();

      // The server stored the full blob (id sent as '' is ignored).
      final stored = server.getChatById(serverId)!;
      final history = (stored['chat'] as Map)['history'] as Map;
      check((history['messages'] as Map).length).equals(2);
      check(locksIdle(chatLocks)).isTrue();
    });

    test('blob id is sent empty; the server mints the row id', () async {
      const localId = 'local:idcheck';
      await seedLocalChat(db, id: localId, messageCount: 1);
      final serverId = await push.pushCreateChat(localId);
      // Server-minted id is a fresh uuid, never the local id nor empty.
      check(serverId).isNotNull();
      check(serverId).not((it) => it.equals(localId));
      check(serverId!.startsWith('local:')).isFalse();
    });

    test(
      'returns null when the chat was deleted before the push ran',
      () async {
        check(await push.pushCreateChat('local:ghost')).isNull();
        check(client.createChatCalls).equals(0);
      },
    );

    test('consumes a successful create when its local source disappears before '
        'remap', () async {
      const localId = 'local:purged-after-create';
      await seedLocalChat(db, id: localId, messageCount: 1);
      final deletingClient = _DeleteSourceAfterCreateClient(
        server,
        db: db,
        localId: localId,
      );
      final deletingPush = PushSync(
        client: deletingClient,
        db: db,
        chatLocks: chatLocks,
        folderLocks: folderLocks,
        clock: clock,
        remapper: remapper,
      );

      final serverId = await deletingPush.pushCreateChat(localId);

      check(serverId).isNotNull();
      check(deletingClient.createChatCalls).equals(1);
      check(await db.chatsDao.getChat(localId)).isNull();
      check(await db.chatsDao.getChat(serverId!)).isNull();
      check(server.getChatById(serverId)).isNotNull();

      // A stale retry sees that the local source is gone and cannot repeat
      // the already-successful remote create.
      check(await deletingPush.pushCreateChat(localId)).isNull();
      check(deletingClient.createChatCalls).equals(1);
      check(server.getChatList(page: 1)).length.equals(1);
    });

    test('re-run with an already-remapped (non-local) id does NOT POST a '
        'duplicate (Finding 2)', () async {
      // First create: local -> server, remap commits.
      const localId = 'local:dup';
      await seedLocalChat(db, id: localId, messageCount: 1);
      final serverId = await push.pushCreateChat(localId);
      check(client.createChatCalls).equals(1);

      // Simulate the crash window: the remap repointed the still-live op's
      // chat_id to serverId, but markDone never ran. A re-claim hands the op
      // back with the SERVER id. pushCreateChat must treat it as satisfied.
      final reResult = await push.pushCreateChat(serverId!);
      check(reResult).equals(serverId);
      // Still exactly one createChat POST — no duplicate chat on the server.
      check(client.createChatCalls).equals(1);
    });

    test('a re-run that sends nothing leaves a newer copy, read before it, '
        'to be stored', () async {
      const localId = 'local:rerun';
      await seedLocalChat(db, id: localId, messageCount: 1);
      final serverId = (await push.pushCreateChat(localId))!;

      // Edited on another device a second later.
      final blob =
          server.getChatById(serverId)!['chat'] as Map<String, dynamic>;
      final history = blob['history'] as Map<String, dynamic>;
      final messages = history['messages'] as Map<String, dynamic>;
      (messages['$localId-m1'] as Map<String, dynamic>)['content'] =
          'Sow the peas in March.';
      server.seedChat(
        id: serverId,
        blob: blob,
        createdAt: 7000,
        updatedAt: 7001,
      );

      // A pull reads that copy...
      final read = Completer<void>();
      final release = Completer<void>();
      final reader = _HeldChatReadClient(server, read: read, release: release);
      final pulling = PullSync(
        client: reader,
        db: db,
        locks: chatLocks,
        remapper: remapper,
      ).pullChat(serverId);
      await read.future;
      // ...the create runs again (its done mark was lost) and finds the chat
      // on the server already, so nothing is sent...
      check(await push.pushCreateChat(serverId)).equals(serverId);
      check(client.createChatCalls).equals(1);
      // ...and the copy comes back after it.
      release.complete();
      await pulling;

      final stored = await db.messagesDao.getForChat(serverId);
      check(stored.single.content).equals('Sow the peas in March.');
      check(await db.chatsDao.getChat(serverId))
          .isNotNull()
          .has((c) => c.serverUpdatedAt, 'serverUpdatedAt')
          .equals(7001);
      // Stored as it was read, with no second read.
      check(reader.reads).equals(1);
    });

    test('a re-run after a params edit leaves the edit to the update still '
        'owed, past a copy from before it read in the same second', () async {
      const localId = 'local:params-edit';
      await seedLocalChat(db, id: localId, messageCount: 1);
      final contentHash = createChatContentHash(
        chatRowsFromDb(
          (await db.chatsDao.getChat(localId))!,
          await db.messagesDao.getForChat(localId),
        ),
      );
      final serverId = (await push.pushCreateChat(
        localId,
        contentHash: contentHash,
      ))!;

      // A pull reads the chat...
      final read = Completer<void>();
      final release = Completer<void>();
      final pulling = PullSync(
        client: _HeldChatReadClient(server, read: read, release: release),
        db: db,
        locks: chatLocks,
        remapper: remapper,
      ).pullChat(serverId);
      await read.future;
      // ...its temperature is changed here, in the same second...
      await chatLocks.runExclusive(
        serverId,
        () => db.chatsDao.patchChatParamsWithOutbox(
          serverId,
          set: {'temperature': 0.2},
          updatedAt: 7000,
        ),
      );
      // ...the create runs again (its done mark was lost) and sends
      // nothing...
      check(await push.pushCreateChat(serverId, contentHash: contentHash))
          .equals(serverId);
      check(client.createChatCalls).equals(1);
      // ...and the copy from before the edit comes back after it.
      release.complete();
      await pulling;

      check(await db.chatsDao.getChatParams(serverId))
          .isNotNull()
          .deepEquals({'temperature': 0.2});
      // The update the edit queued sends it.
      check(await outboxOpsForChat(db, serverId)).single
          .has((op) => op.kind, 'kind')
          .equals(OutboxKind.updateChat.name);
      await push.pushUpdateChat(serverId);
      check((server.getChatById(serverId)!['chat'] as Map)['params'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'temperature': 0.2});
    });

    test('a re-run after a pin, which its snapshot leaves out, leaves the pin '
        'to the update still owed', () async {
      const localId = 'local:pin-after-create';
      await seedLocalChat(db, id: localId, messageCount: 1);
      final contentHash = createChatContentHash(
        chatRowsFromDb(
          (await db.chatsDao.getChat(localId))!,
          await db.messagesDao.getForChat(localId),
        ),
      );
      final serverId = (await push.pushCreateChat(
        localId,
        contentHash: contentHash,
      ))!;

      // Pinned here, then the create runs again and sends nothing...
      await chatLocks.runExclusive(
        serverId,
        () => db.chatsDao.updateEnvelopeWithOutbox(
          serverId,
          pinned: const Value(true),
          enqueue: true,
        ),
      );
      check(await push.pushCreateChat(serverId, contentHash: contentHash))
          .equals(serverId);
      // ...and the chat is pulled by name, in the same second.
      await PullSync(
        client: client,
        db: db,
        locks: chatLocks,
        remapper: remapper,
      ).pullChat(serverId);

      check(await db.chatsDao.getChat(serverId))
          .isNotNull()
          .has((c) => c.pinned, 'pinned')
          .isTrue();
      await push.pushUpdateChat(serverId);
      check(server.getChatById(serverId)!['pinned']).equals(true);
    });

    test('an edit made while a create that reached the server waits to run '
        'again is still sent', () async {
      const localId = 'local:waiting-create';
      await seedLocalChat(db, id: localId, messageCount: 1);
      final contentHash = createChatContentHash(
        chatRowsFromDb(
          (await db.chatsDao.getChat(localId))!,
          await db.messagesDao.getForChat(localId),
        ),
      );
      await db.transaction(
        () => db.outboxDao.enqueue(
          kind: OutboxKind.createChat,
          chatId: localId,
          contentHash: contentHash,
        ),
      );
      // The create reaches the server and its op takes the server id with
      // the row, but its done mark is lost...
      final serverId = (await push.pushCreateChat(
        localId,
        contentHash: contentHash,
      ))!;
      // ...and the temperature is changed before it runs again.
      await chatLocks.runExclusive(
        serverId,
        () => db.chatsDao.patchChatParamsWithOutbox(
          serverId,
          set: {'temperature': 0.2},
          updatedAt: 7000,
        ),
      );

      final ops = await outboxOpsForChat(db, serverId)
        ..sort((a, b) => a.seq.compareTo(b.seq));
      for (final op in ops) {
        if (op.kind == OutboxKind.createChat.name) {
          await push.pushCreateChat(op.chatId!, contentHash: op.contentHash);
        } else if (op.kind == OutboxKind.updateChat.name) {
          await push.pushUpdateChat(op.chatId!);
        }
        await db.outboxDao.markDone(op.seq);
      }

      check(client.createChatCalls).equals(1);
      check((server.getChatById(serverId)!['chat'] as Map)['params'])
          .isA<Map<String, dynamic>>()
          .deepEquals({'temperature': 0.2});
    });

    test('a checklist event that comes while a copy from before the create '
        'is read is kept', () async {
      const localId = 'local:checklist';
      await seedLocalChat(db, id: localId, messageCount: 1);
      final created = Completer<String>();
      final answered = Completer<void>();
      final creating = PushSync(
        client: _HeldCreateClient(server, created: created, release: answered),
        db: db,
        chatLocks: chatLocks,
        folderLocks: folderLocks,
        clock: clock,
        remapper: remapper,
      ).pushCreateChat(localId);
      final serverId = await created.future;

      // A pull reads the new chat before the create's answer is back...
      final read = Completer<void>();
      final release = Completer<void>();
      final pulling = PullSync(
        client: _HeldChatReadClient(server, read: read, release: release),
        db: db,
        locks: chatLocks,
        remapper: remapper,
      ).pullChat(serverId);
      await read.future;
      // ...a checklist event comes for it, with no row under its id yet...
      final tasks = <Map<String, dynamic>>[
        {'id': '1', 'content': 'Water the seedlings', 'status': 'completed'},
      ];
      await chatLocks.runExclusive(
        serverId,
        () => db.chatsDao.updateServerTasks(serverId, tasks),
      );
      // ...the answer lands and the row takes the server id...
      answered.complete();
      await creating;
      // ...and the copy read before all that comes back.
      release.complete();
      await pulling;

      final meta = jsonDecode((await db.chatsDao.getChat(serverId))!.meta);
      check(meta as Map<String, dynamic>)
          .has((m) => m['_conduit_tasks'], 'tasks')
          .isA<List<dynamic>>()
          .deepEquals(tasks);
    });

    test(
      're-run with an already-remapped id keeps newer dirty messages dirty',
      () async {
        const localId = 'local:dirty-replay';
        await seedLocalChat(db, id: localId, messageCount: 1);
        final serverId = await push.pushCreateChat(localId);
        final message = (await db.messagesDao.getForChat(serverId!)).single;
        await (db.update(db.messages)..where(
              (t) => t.chatId.equals(serverId) & t.id.equals(message.id),
            ))
            .write(const MessagesCompanion(dirty: Value(true)));

        final reResult = await push.pushCreateChat(
          serverId,
          contentHash: 'older-snapshot',
        );

        check(reResult).equals(serverId);
        check(client.createChatCalls).equals(1);
        final messages = await db.messagesDao.getForChat(serverId);
        check(messages.single.dirty).isTrue();
      },
    );

    test('defers create while the target folder is still local', () async {
      const localId = 'local:foldered-chat';
      const folderId = 'local:folder';
      await seedLocalChat(db, id: localId, folderId: folderId, messageCount: 1);

      await check(push.pushCreateChat(localId))
          .throws<OutboxDeferralException>();

      check(client.createChatCalls).equals(0);
      final chat = await db.chatsDao.getChat(localId);
      check(chat).isNotNull();
      check(chat!.folderId).equals(folderId);
      check(chat.dirty).isTrue();
      check(await db.messagesDao.getForChat(localId)).length.equals(1);
    });

    test('remap and dirty clear share one server-id lock span', () async {
      final recordingLocks = _RecordingChatLocks();
      final recordingPush = PushSync(
        client: client,
        db: db,
        chatLocks: recordingLocks,
        folderLocks: folderLocks,
        clock: clock,
        remapper: remapper,
      );
      const localId = 'local:single-span';
      await seedLocalChat(db, id: localId, messageCount: 1);

      final serverId = await recordingPush.pushCreateChat(localId);

      check(serverId).isNotNull();
      check(recordingLocks.keys).deepEquals([localId, serverId!]);
      check(
        recordingLocks.activeSnapshots.any(
          (keys) => keys.contains(localId) && keys.contains(serverId),
        ),
      ).isTrue();
    });
  });

  group('pushUpdateChat', () {
    test('a copy read before a send was pushed, in the same second, does not '
        'take the sent message and its placeholder back out', () async {
      // Open WebUI stamps whole seconds: the stored chat, the push below
      // and the copy a pull reads in between all carry 7000.
      server.seedChat(
        id: 'srv-race',
        blob: {
          'title': 'Seed beds',
          'models': ['llama3'],
          'history': {
            'messages': {
              'q1': {
                'id': 'q1',
                'parentId': null,
                'childrenIds': ['a1'],
                'role': 'user',
                'content': 'When do beans go in?',
              },
              'a1': {
                'id': 'a1',
                'parentId': 'q1',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': 'After the last frost.',
                'done': true,
              },
            },
            'currentId': 'a1',
          },
        },
        createdAt: 100,
        updatedAt: 7000,
      );
      final pull = PullSync(
        client: client,
        db: db,
        locks: chatLocks,
        remapper: remapper,
      );
      await pull.pullChat('srv-race');

      // A send, as `durableSend` commits it: the question and its answer's
      // empty placeholder, pending a push and a completion.
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: 'srv-race',
        messages: <MessageRowData>[
          MessageRowData(
            id: 'q2',
            chatId: 'srv-race',
            parentId: 'a1',
            role: 'user',
            content: 'And the herbs?',
            createdAt: 7000,
            orderIndex: 0,
            payload: <String, dynamic>{
              'id': 'q2',
              'parentId': 'a1',
              'childrenIds': ['a2'],
              'role': 'user',
              'content': 'And the herbs?',
            },
          ),
          MessageRowData(
            id: 'a2',
            chatId: 'srv-race',
            parentId: 'q2',
            role: 'assistant',
            content: '',
            createdAt: 7000,
            orderIndex: 1,
            payload: <String, dynamic>{
              'id': 'a2',
              'parentId': 'q2',
              'childrenIds': <String>[],
              'role': 'assistant',
              'content': '',
            },
          ),
        ],
        currentMessageId: 'a2',
        updatedAt: 7000,
        enqueueCompletion: false,
      );

      // Another pull reads the chat now, before the push...
      final read = Completer<void>();
      final release = Completer<void>();
      final racing = PullSync(
        client: _HeldChatReadClient(server, read: read, release: release),
        db: db,
        locks: chatLocks,
        remapper: remapper,
      );
      final pulling = racing.pullChat('srv-race');
      await read.future;
      // ...the push lands, in the same second...
      await push.pushUpdateChat('srv-race');
      check(await db.chatsDao.getChat('srv-race'))
          .isNotNull()
          .has((c) => c.serverUpdatedAt, 'serverUpdatedAt')
          .equals(7000);
      // ...and the copy from before it is stored after it.
      release.complete();
      await pulling;

      final ids = [
        for (final m in await db.messagesDao.getForChat('srv-race')) m.id,
      ];
      check(ids).deepEquals(['q1', 'a1', 'q2', 'a2']);
      // The answer is written on the server in that same second, and the
      // next pull, read after the push, takes it as before.
      final blob =
          server.getChatById('srv-race')!['chat'] as Map<String, dynamic>;
      final history = blob['history'] as Map<String, dynamic>;
      final messages = history['messages'] as Map<String, dynamic>;
      (messages['a2'] as Map<String, dynamic>)
        ..['content'] = 'Basil once the nights are warm.'
        ..['done'] = true;
      server.seedChat(
        id: 'srv-race',
        blob: blob,
        createdAt: 100,
        updatedAt: 7000,
      );
      await pull.pullChat('srv-race');
      final stored = await db.messagesDao.getForChat('srv-race');
      check([for (final m in stored) m.id])
          .deepEquals(['q1', 'a1', 'q2', 'a2']);
      check(stored.last.content).equals('Basil once the nights are warm.');
    });

    test('a copy read before an update reached the server is read again when '
        'the pin after the update fails', () async {
      server.seedChat(
        id: 'srv-pin-fails',
        blob: {
          'title': 'Potting mix',
          'history': {
            'messages': {
              'q1': {
                'id': 'q1',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'What goes in a potting mix?',
              },
            },
            'currentId': 'q1',
          },
        },
        createdAt: 100,
        updatedAt: 7000,
      );
      await PullSync(
        client: client,
        db: db,
        locks: chatLocks,
        remapper: remapper,
      ).pullChat('srv-pin-fails');

      // A message sent and the chat pinned here, pending one push.
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: 'srv-pin-fails',
        messages: <MessageRowData>[
          MessageRowData(
            id: 'q2',
            chatId: 'srv-pin-fails',
            parentId: 'q1',
            role: 'user',
            content: 'And for seedlings?',
            createdAt: 7000,
            orderIndex: 0,
            payload: <String, dynamic>{
              'id': 'q2',
              'parentId': 'q1',
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'And for seedlings?',
            },
          ),
        ],
        currentMessageId: 'q2',
        updatedAt: 7000,
        enqueueCompletion: false,
      );
      await chatLocks.runExclusive(
        'srv-pin-fails',
        () => db.chatsDao.updateEnvelopeWithOutbox(
          'srv-pin-fails',
          pinned: const Value(true),
          enqueue: true,
        ),
      );

      // A pull reads the chat, with the link it is shared by, before the
      // push...
      final read = Completer<void>();
      final release = Completer<void>();
      final reader = _HeldChatReadClient(
        server,
        read: read,
        release: release,
        envelope: {'share_id': 'share-mix'},
      );
      final pulling = PullSync(
        client: reader,
        db: db,
        locks: chatLocks,
        remapper: remapper,
      ).pullChat('srv-pin-fails');
      await read.future;
      // ...the update lands, in the same second, and the pin after it
      // fails...
      await check(
        PushSync(
          client: _PinFailsClient(server),
          db: db,
          chatLocks: chatLocks,
          folderLocks: folderLocks,
          clock: clock,
          remapper: remapper,
        ).pushUpdateChat('srv-pin-fails'),
      ).throws<StateError>();
      final history =
          (server.getChatById('srv-pin-fails')!['chat'] as Map)['history']
              as Map;
      check((history['messages'] as Map).keys).contains('q2');
      // ...the link is taken down elsewhere...
      reader.envelope = const {'share_id': null};
      // ...and the copy from before the update comes back after it.
      release.complete();
      await pulling;

      // None of it is stored: the chat is read again, link and all.
      check(reader.reads).equals(2);
      check(await db.chatsDao.getChat('srv-pin-fails'))
          .isNotNull()
          .has((c) => c.shareId, 'shareId')
          .isNull();
    });

    for (final byName in [false, true]) {
      test(
        'tags and a share link read with a copy from before a push still '
        'arrive (${byName ? 'a pull asked for by name' : 'a pull cycle'})',
        () async {
          server.seedChat(
            id: 'srv-tags',
            blob: {
              'title': 'Bean rows',
              'models': ['llama3'],
              'history': {
                'messages': {
                  'q1': {
                    'id': 'q1',
                    'parentId': null,
                    'childrenIds': ['a1'],
                    'role': 'user',
                    'content': 'How far apart are bean rows?',
                  },
                  'a1': {
                    'id': 'a1',
                    'parentId': 'q1',
                    'childrenIds': <String>[],
                    'role': 'assistant',
                    'content': 'About 45 cm.',
                    'done': true,
                  },
                },
                'currentId': 'a1',
              },
            },
            createdAt: 100,
            updatedAt: 7000,
          );
          await PullSync(
            client: client,
            db: db,
            locks: chatLocks,
            remapper: remapper,
          ).pullChat('srv-tags');

          // A message sent here, pending its push.
          await db.chatsDao.appendMessagesWithUpdateOp(
            chatId: 'srv-tags',
            messages: <MessageRowData>[
              MessageRowData(
                id: 'q2',
                chatId: 'srv-tags',
                parentId: 'a1',
                role: 'user',
                content: 'And for peas?',
                createdAt: 7000,
                orderIndex: 0,
                payload: <String, dynamic>{
                  'id': 'q2',
                  'parentId': 'a1',
                  'childrenIds': <String>[],
                  'role': 'user',
                  'content': 'And for peas?',
                },
              ),
            ],
            currentMessageId: 'q2',
            updatedAt: 7000,
            enqueueCompletion: false,
          );

          // Tagged and shared elsewhere, which leaves `updated_at` alone. A
          // pull reads the chat, tags and link included, before the push...
          final read = Completer<void>();
          final release = Completer<void>();
          final racing = PullSync(
            client: _HeldChatReadClient(
              server,
              read: read,
              release: release,
              envelope: {
                'meta': {
                  'tags': ['garden'],
                },
                'share_id': 'share-beans',
              },
            ),
            db: db,
            locks: chatLocks,
            remapper: remapper,
          );
          final Future<Object?> pulling = byName
              ? racing.pullChat('srv-tags')
              : racing.run();
          await read.future;
          // ...the push lands, in the same second...
          await push.pushUpdateChat('srv-tags');
          // ...and the copy from before it comes back after it.
          release.complete();
          await pulling;

          final chat = (await db.chatsDao.getChat('srv-tags'))!;
          check(jsonDecode(chat.meta) as Map<String, dynamic>)
              .has((m) => m['tags'], 'tags')
              .isA<List<dynamic>>()
              .deepEquals(['garden']);
          check(chat.shareId).equals('share-beans');
          check([
            for (final m in await db.messagesDao.getForChat('srv-tags')) m.id,
          ]).deepEquals(['q1', 'a1', 'q2']);
        },
      );
    }

    test('a cycle whose every read of a chat predates a push of it leaves the '
        'chat for the next cycle to read', () async {
      server.seedChat(
        id: 'srv-memo',
        blob: {
          'title': 'Compost',
          'history': {
            'messages': {
              'q1': {
                'id': 'q1',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'How often to turn compost?',
              },
            },
            'currentId': 'q1',
          },
        },
        createdAt: 100,
        updatedAt: 7000,
      );
      var elapsedMs = 0;
      final memo = PullFetchMemo(elapsedMs: () => elapsedMs);
      final reader = _ReadHookClient(server);
      Future<void> cycle() => PullSync(
        client: reader,
        db: db,
        locks: chatLocks,
        remapper: remapper,
        fetchMemo: memo,
      ).run();
      Future<Object?> tags() async =>
          (jsonDecode((await db.chatsDao.getChat('srv-memo'))!.meta)
              as Map)['tags'];
      var sent = 1;
      Future<void> sendAndPush() async {
        final id = 'q${sent + 1}';
        final parentId = 'q$sent';
        sent++;
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: 'srv-memo',
          messages: <MessageRowData>[
            MessageRowData(
              id: id,
              chatId: 'srv-memo',
              parentId: parentId,
              role: 'user',
              content: 'And $id?',
              createdAt: 7000,
              orderIndex: 0,
              payload: <String, dynamic>{
                'id': id,
                'parentId': parentId,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'And $id?',
              },
            ),
          ],
          currentMessageId: id,
          updatedAt: 7000,
          enqueueCompletion: false,
        );
        await push.pushUpdateChat('srv-memo');
      }

      // A cycle reads and stores the chat at its stamp.
      await cycle();
      check(await db.chatsDao.getChat('srv-memo')).isNotNull();

      // Tagged elsewhere, which leaves `updated_at` alone. The next cycle,
      // past the overlap window, reads it again, but each read is overtaken
      // by a send pushed in the same second: nothing of it is stored.
      reader.envelope = {
        'meta': {
          'tags': ['compost'],
        },
      };
      elapsedMs += kPullOverlapSeconds * 1000;
      reader.afterRead = sendAndPush;
      await cycle();
      check(await tags()).isNull();

      // That is not counted as a read of the stamp, so the cycle after reads
      // the chat again rather than skipping it, and stores the tags.
      reader.afterRead = null;
      elapsedMs += kPullOverlapSeconds * 1000;
      await cycle();
      check(await tags()).isA<List<dynamic>>().deepEquals(['compost']);
      check(await db.chatsDao.getChat('srv-memo'))
          .isNotNull()
          .has((c) => c.serverUpdatedAt, 'serverUpdatedAt')
          .equals(7000);
    });

    test(
      'pushes the FULL reconstructed blob (shallow-merge keeps it intact)',
      () async {
        // Seed a server chat first, then mutate a local row and push.
        server.seedChat(
          id: 'srv-1',
          blob: {
            'title': 'Title srv-1',
            'models': ['llama3'],
            'history': {
              'messages': {
                'srv-1-m1': {
                  'id': 'srv-1-m1',
                  'parentId': null,
                  'role': 'user',
                  'content': 'old content',
                },
              },
              'currentId': 'srv-1-m1',
            },
          },
          createdAt: 100,
          updatedAt: 150,
        );
        // Local edit: new content + a brand-new message.
        await seedLocalChat(db, id: 'srv-1', messageCount: 2, dirty: true);

        await push.pushUpdateChat('srv-1');

        final stored = server.getChatById('srv-1')!;
        final history = (stored['chat'] as Map)['history'] as Map;
        final messages = history['messages'] as Map;
        // Full blob replaced history.messages: both local messages present.
        check(messages.keys.toSet()).deepEquals({'srv-1-m1', 'srv-1-m2'});
        // Top-level `models` survived (full blob carried it).
        check((stored['chat'] as Map)['models'] as List).deepEquals(['llama3']);

        // serverUpdatedAt stored, dirty cleared for chat + its messages.
        final chat = await db.chatsDao.getChat('srv-1');
        check(chat!.serverUpdatedAt).equals(7000);
        check(chat.dirty).isFalse();
        final msgs = await db.messagesDao.getForChat('srv-1');
        check(msgs.every((m) => !m.dirty)).isTrue();
      },
    );

    test('clears dirty messages in batches for very large chats', () async {
      server.seedChat(
        id: 'srv-many',
        blob: {
          'title': 'Title srv-many',
          'history': {'messages': <String, dynamic>{}, 'currentId': null},
        },
        createdAt: 100,
        updatedAt: 150,
      );
      await seedLocalChat(db, id: 'srv-many', messageCount: 1200, dirty: true);

      await push.pushUpdateChat('srv-many');

      final chat = await db.chatsDao.getChat('srv-many');
      check(chat!.dirty).isFalse();
      final msgs = await db.messagesDao.getForChat('srv-many');
      check(msgs).length.equals(1200);
      check(msgs.every((m) => !m.dirty)).isTrue();
    });

    test('defers update when the chat body is only an envelope stub', () async {
      server.seedChat(
        id: 'stub',
        blob: {
          'title': 'Server title',
          'history': {
            'messages': {
              'server-old': {
                'id': 'server-old',
                'parentId': null,
                'role': 'user',
                'content': 'server history',
              },
            },
            'currentId': 'server-old',
          },
        },
        createdAt: 100,
        updatedAt: 150,
      );
      await seedLocalChat(
        db,
        id: 'stub',
        messageCount: 2,
        dirty: true,
        bodySynced: false,
      );

      await check(push.pushUpdateChat('stub'))
          .throws<OutboxDeferralException>();

      final stored = server.getChatById('stub')!;
      final history = (stored['chat'] as Map)['history'] as Map;
      final messages = history['messages'] as Map;
      check(messages.keys.toSet()).deepEquals({'server-old'});
      check((await db.chatsDao.getChat('stub'))!.dirty).isTrue();
    });

    test('respects the server shallow-merge + output->content re-derivation', () async {
      // Server has an assistant message with no output.
      server.seedChat(
        id: 'srv-out',
        blob: {
          'title': 'Title srv-out',
          'history': {
            'messages': {
              'a1': {'id': 'a1', 'role': 'assistant', 'content': 'stale'},
            },
            'currentId': 'a1',
          },
        },
        createdAt: 1,
        updatedAt: 2,
      );
      // Local row carries an assistant message whose payload has a NEW output
      // list; the server must re-derive content from it.
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'srv-out',
              title: 'Title srv-out',
              currentMessageId: const Value('a1'),
              createdAt: 1,
              updatedAt: 2,
              dirty: const Value(true),
              bodySynced: const Value(true),
              blobMeta: Value(
                jsonEncode(<String, dynamic>{
                  'v': 1,
                  'blobHadTitle': true,
                  'blobTitleValue': 'Title srv-out',
                  'blobHadHistory': true,
                  'historyHadMessages': true,
                  'historyHadCurrentId': true,
                  'historyExtra': <String, dynamic>{},
                  'unmappableMessages': <String, dynamic>{},
                }),
              ),
            ),
          );
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'a1',
              chatId: 'srv-out',
              role: 'assistant',
              content: 'ignored-by-server',
              createdAt: 5,
              orderIndex: 0,
              payload: jsonEncode(<String, dynamic>{
                'id': 'a1',
                'role': 'assistant',
                'content': 'ignored-by-server',
                'output': [
                  {
                    'type': 'message',
                    'content': [
                      {'text': 'derived body'},
                    ],
                  },
                ],
              }),
              dirty: const Value(true),
            ),
          );

      await push.pushUpdateChat('srv-out');

      final stored = server.getChatById('srv-out')!;
      final msg =
          ((stored['chat'] as Map)['history'] as Map)['messages']['a1'] as Map;
      // Content was re-derived from output by the server, NOT the local value.
      check(msg['content']).equals('derived body');
    });

    test('pin/archive toggle-delta fires only on a real delta', () async {
      server.seedChat(
        id: 'srv-pin',
        blob: {
          'title': 'p',
          'history': {'messages': {}, 'currentId': null},
        },
        createdAt: 1,
        updatedAt: 2,
        pinned: false,
        archived: false,
      );
      // Local wants pinned=true, archived=true.
      await seedLocalChat(
        db,
        id: 'srv-pin',
        messageCount: 0,
        pinned: true,
        archived: true,
      );

      await push.pushUpdateChat('srv-pin');

      final stored = server.getChatById('srv-pin')!;
      check(stored['pinned']).equals(true);
      check(stored['archived']).equals(true);
    });

    test('pin-only toggle skips redundant chat body fetch', () async {
      server.seedChat(
        id: 'srv-pin-only',
        blob: {
          'title': 'p',
          'history': {'messages': {}, 'currentId': null},
        },
        createdAt: 1,
        updatedAt: 2,
        pinned: false,
        archived: false,
      );
      await seedLocalChat(
        db,
        id: 'srv-pin-only',
        messageCount: 0,
        pinned: true,
        archived: false,
      );

      await push.pushUpdateChat('srv-pin-only');

      final stored = server.getChatById('srv-pin-only')!;
      check(stored['pinned']).equals(true);
      check(stored['archived']).equals(false);
      check(client.chatFetchStarts).isEmpty();
    });

    test(
      'pin mismatch adopts server state without parking updateChat',
      () async {
        final racingClient = _RevertPinToggleClient(server);
        push = PushSync(
          client: racingClient,
          db: db,
          chatLocks: chatLocks,
          folderLocks: folderLocks,
          clock: clock,
          remapper: remapper,
        );
        server.seedChat(
          id: 'srv-pin-mismatch',
          blob: {
            'title': 'pin',
            'history': {'messages': {}, 'currentId': null},
          },
          createdAt: 1,
          updatedAt: 2,
          pinned: false,
          archived: false,
        );
        await seedLocalChat(
          db,
          id: 'srv-pin-mismatch',
          messageCount: 0,
          pinned: true,
          archived: false,
        );

        await push.pushUpdateChat('srv-pin-mismatch');

        final chat = await db.chatsDao.getChat('srv-pin-mismatch');
        check(chat).isNotNull();
        check(chat!.pinned).isFalse();
        check(chat.dirty).isFalse();
        final stored = server.getChatById('srv-pin-mismatch')!;
        check(stored['pinned']).equals(false);
      },
    );

    test('post-toggle archive 404 does not park updateChat', () async {
      final racingClient = _DeleteAfterArchiveToggleClient(server);
      push = PushSync(
        client: racingClient,
        db: db,
        chatLocks: chatLocks,
        folderLocks: folderLocks,
        clock: clock,
        remapper: remapper,
      );
      server.seedChat(
        id: 'srv-archive-race',
        blob: {
          'title': 'archive',
          'history': {'messages': {}, 'currentId': null},
        },
        createdAt: 1,
        updatedAt: 2,
        archived: false,
      );
      await seedLocalChat(
        db,
        id: 'srv-archive-race',
        messageCount: 0,
        archived: true,
      );

      await push.pushUpdateChat('srv-archive-race');

      final chat = await db.chatsDao.getChat('srv-archive-race');
      check(chat).isNotNull();
      check(chat!.dirty).isFalse();
      check(server.getChatById('srv-archive-race')).isNull();
    });

    test(
      'archive mismatch adopts server state without parking updateChat',
      () async {
        final racingClient = _RevertArchiveToggleClient(server);
        push = PushSync(
          client: racingClient,
          db: db,
          chatLocks: chatLocks,
          folderLocks: folderLocks,
          clock: clock,
          remapper: remapper,
        );
        server.seedChat(
          id: 'srv-archive-mismatch',
          blob: {
            'title': 'archive',
            'history': {'messages': {}, 'currentId': null},
          },
          createdAt: 1,
          updatedAt: 2,
          archived: false,
        );
        await seedLocalChat(
          db,
          id: 'srv-archive-mismatch',
          messageCount: 0,
          archived: true,
        );

        await push.pushUpdateChat('srv-archive-mismatch');

        final chat = await db.chatsDao.getChat('srv-archive-mismatch');
        check(chat).isNotNull();
        check(chat!.archived).isFalse();
        check(chat.dirty).isFalse();
        final stored = server.getChatById('srv-archive-mismatch')!;
        check(stored['archived']).equals(false);
      },
    );

    test(
      'folder-move delta routes through the dedicated /folder endpoint',
      () async {
        server.seedFolder('srv-folder');
        server.seedChat(
          id: 'srv-mv',
          blob: {
            'title': 'm',
            'history': {'messages': {}, 'currentId': null},
          },
          createdAt: 1,
          updatedAt: 2,
        );
        await seedLocalChat(
          db,
          id: 'srv-mv',
          messageCount: 0,
          folderId: 'srv-folder',
        );

        await push.pushUpdateChat('srv-mv');

        check(server.getChatById('srv-mv')!['folder_id']).equals('srv-folder');
      },
    );

    test('pin survives a folder move (move resets server pin; reconcile re-asserts)', () async {
      server.seedFolder('srv-folder');
      // Server chat is pinned and unfiled; the local row both pins it and
      // moves it into the folder in one coalesced update. The /folder
      // endpoint forces pinned=false server-side, so the pin reconcile must
      // run AFTER the move (and treat the post-move pin as false) or the
      // desired pinned=true is silently lost.
      server.seedChat(
        id: 'srv-mv-pin',
        blob: {
          'title': 'm',
          'history': {'messages': {}, 'currentId': null},
        },
        createdAt: 1,
        updatedAt: 2,
        pinned: true,
      );
      await seedLocalChat(
        db,
        id: 'srv-mv-pin',
        messageCount: 0,
        folderId: 'srv-folder',
        pinned: true,
      );

      await push.pushUpdateChat('srv-mv-pin');

      final stored = server.getChatById('srv-mv-pin')!;
      check(stored['folder_id']).equals('srv-folder');
      check(stored['pinned']).equals(true);
      final chat = await db.chatsDao.getChat('srv-mv-pin');
      check(chat!.dirty).isFalse();
    });

    test(
      '404 (chat gone) is non-fatal: logs and returns, no dirty cleared',
      () async {
        await seedLocalChat(db, id: 'absent', messageCount: 1, dirty: true);
        // No server chat seeded -> updateChat returns null (404).
        await push.pushUpdateChat('absent');
        // Dirty stays set (nothing confirmed).
        final chat = await db.chatsDao.getChat('absent');
        check(chat!.dirty).isTrue();
        check(chat.serverUpdatedAt).isNull();
      },
    );

    test('skips a tombstoned chat (a deleteChat op will handle it)', () async {
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'tomb',
              title: 't',
              createdAt: 1,
              updatedAt: 2,
              deleted: const Value(true),
              dirty: const Value(true),
            ),
          );
      await push.pushUpdateChat('tomb');
      check(client.updateChatCalls).equals(0);
    });
  });

  group('pushDeleteChat', () {
    test('confirms server delete then purges local rows', () async {
      server.seedChat(
        id: 'srv-del',
        blob: {
          'title': 'd',
          'history': {'messages': {}, 'currentId': null},
        },
        createdAt: 1,
        updatedAt: 2,
      );
      await seedLocalChat(db, id: 'srv-del', messageCount: 2);

      await push.pushDeleteChat('srv-del');

      check(server.getChatById('srv-del')).isNull();
      check(await db.chatsDao.getChat('srv-del')).isNull();
      check(await db.messagesDao.getForChat('srv-del')).isEmpty();
    });

    test('purges parked outbox ops for the deleted chat', () async {
      server.seedChat(
        id: 'srv-del-parked',
        blob: {
          'title': 'd',
          'history': {'messages': {}, 'currentId': null},
        },
        createdAt: 1,
        updatedAt: 2,
      );
      await seedLocalChat(db, id: 'srv-del-parked', messageCount: 1);
      await db
          .into(db.outboxOps)
          .insert(
            OutboxOpsCompanion.insert(
              kind: OutboxKind.updateChat.name,
              chatId: const Value('srv-del-parked'),
              status: const Value(OutboxStatus.failed),
              attempts: const Value(5),
              lastError: const Value('parked update'),
            ),
          );

      await push.pushDeleteChat('srv-del-parked');

      check(await db.chatsDao.getChat('srv-del-parked')).isNull();
      final remaining = await (db.select(
        db.outboxOps,
      )..where((t) => t.chatId.equals('srv-del-parked'))).get();
      check(remaining).isEmpty();
    });

    test(
      '404 (already gone) still purges local rows without throwing',
      () async {
        await seedLocalChat(db, id: 'srv-gone', messageCount: 1);
        // No server chat -> deleteChat returns false; purge proceeds.
        await push.pushDeleteChat('srv-gone');
        check(await db.chatsDao.getChat('srv-gone')).isNull();
      },
    );

    test('terminal 403 propagates and leaves local rows intact', () async {
      server.seedChat(
        id: 'srv-perm',
        blob: {
          'title': 'p',
          'history': {'messages': {}, 'currentId': null},
        },
        createdAt: 1,
        updatedAt: 2,
      );
      await seedLocalChat(db, id: 'srv-perm', messageCount: 1);
      client.terminalWriteIds.add('srv-perm');

      await check(push.pushDeleteChat('srv-perm')).throws<Exception>();
      // Rows NOT purged (drainer would park the op; tombstone stays).
      check(await db.chatsDao.getChat('srv-perm')).isNotNull();
    });
  });

  group('pushFolderUpsert / pushFolderDelete', () {
    test(
      'local folder create -> server create + remap + dirty clear',
      () async {
        const localId = 'local:fold';
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: localId,
                name: 'Work',
                createdAt: 100,
                updatedAt: 200,
                dirty: const Value(true),
              ),
            );

        await push.pushFolderUpsert(<String, dynamic>{
          'folderId': localId,
          'name': 'Work',
          'parentId': null,
          'data': {
            'files': ['file-1'],
          },
          'meta': {'color': '#336699'},
          'createIfAbsent': true,
        });

        // Local folder remapped to a server id; exactly one folder row, not
        // dirty.
        final folders = await db.select(db.folders).get();
        check(folders.length).equals(1);
        check(folders.single.id.startsWith('local:')).isFalse();
        check(folders.single.dirty).isFalse();
        final serverFolder = server.getFolders().single;
        check(serverFolder['name']).equals('Work');
        check(serverFolder['data']).isA<Map<String, dynamic>>().deepEquals({
          'files': ['file-1'],
        });
        check(serverFolder['meta'])
            .isA<Map<String, dynamic>>()
            .deepEquals({'color': '#336699'});
      },
    );

    test(
      'local folder create defers while its parent is still local',
      () async {
        const localId = 'local:child-folder';
        const parentId = 'local:parent-folder';
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: localId,
                name: 'Child',
                parentId: const Value(parentId),
                createdAt: 100,
                updatedAt: 200,
                dirty: const Value(true),
              ),
            );

        await check(
          push.pushFolderUpsert(<String, dynamic>{
            'folderId': localId,
            'name': 'Child',
            'parentId': parentId,
            'createIfAbsent': true,
          }),
        ).throws<OutboxDeferralException>();

        check(server.getFolders()).isEmpty();
        final row = await db.foldersDao.getFolder(localId);
        check(row).isNotNull();
        check(row!.dirty).isTrue();
      },
    );

    test('local folder create rejects a missing folder name', () async {
      await check(
        push.pushFolderUpsert(<String, dynamic>{
          'folderId': 'local:missing-name',
          'createIfAbsent': true,
        }),
      ).throws<SyncTerminalException>();

      check(server.getFolders()).isEmpty();
    });

    test('existing folder update pushes name + parent', () async {
      final created = server.createFolder(name: 'Old');
      final id = created['id'] as String;
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion.insert(
              id: id,
              name: 'New',
              parentId: const Value('parent-x'),
              createdAt: 1,
              updatedAt: 2,
              dirty: const Value(true),
            ),
          );

      await push.pushFolderUpsert(<String, dynamic>{
        'folderId': id,
        'name': 'New',
        'parentId': 'parent-x',
        'createIfAbsent': false,
      });

      final stored = server.getFolders().firstWhere((f) => f['id'] == id);
      check(stored['name']).equals('New');
      check(stored['parent_id']).equals('parent-x');
      check((await db.select(db.folders).get()).single.dirty).isFalse();
    });

    test('existing folder update 404 purges the local row', () async {
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion.insert(
              id: 'missing-folder',
              name: 'Ghost',
              createdAt: 1,
              updatedAt: 2,
              dirty: const Value(true),
            ),
          );
      await seedParkedFolderOp(db, 'missing-folder');

      await push.pushFolderUpsert(<String, dynamic>{
        'folderId': 'missing-folder',
        'name': 'Ghost',
        'createIfAbsent': false,
      });

      final row = await db.foldersDao.getFolder('missing-folder');
      check(row).isNull();
      check(await outboxOpsForChat(db, 'missing-folder')).isEmpty();
    });

    test('existing folder parent update 404 purges the local row', () async {
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion.insert(
              id: 'missing-parent-folder',
              name: 'Ghost',
              createdAt: 1,
              updatedAt: 2,
              dirty: const Value(true),
            ),
          );
      await seedParkedFolderOp(db, 'missing-parent-folder');

      await push.pushFolderUpsert(<String, dynamic>{
        'folderId': 'missing-parent-folder',
        'parentId': 'parent-x',
        'createIfAbsent': false,
      });

      final row = await db.foldersDao.getFolder('missing-parent-folder');
      check(row).isNull();
      check(await outboxOpsForChat(db, 'missing-parent-folder')).isEmpty();
    });

    test(
      'existing folder parent update defers while parent is still local',
      () async {
        final created = server.createFolder(name: 'Old');
        final id = created['id'] as String;
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: id,
                name: 'Old',
                createdAt: 1,
                updatedAt: 2,
                dirty: const Value(true),
              ),
            );

        await check(
          push.pushFolderUpsert(<String, dynamic>{
            'folderId': id,
            'parentId': 'local:parent-folder',
            'createIfAbsent': false,
          }),
        ).throws<OutboxDeferralException>();

        final stored = server.getFolders().firstWhere((f) => f['id'] == id);
        check(stored['parent_id']).isNull();
        final row = await db.foldersDao.getFolder(id);
        check(row).isNotNull();
        check(row!.dirty).isTrue();
      },
    );

    test(
      'folder delete uses delete_contents=false and purges the row',
      () async {
        final created = server.createFolder(name: 'Doomed');
        final id = created['id'] as String;
        // A chat inside the folder must survive (re-parented to root).
        server.seedChat(
          id: 'kept',
          blob: {
            'title': 'k',
            'history': {'messages': {}, 'currentId': null},
          },
          createdAt: 1,
          updatedAt: 2,
          folderId: id,
        );
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: id,
                name: 'Doomed',
                createdAt: 1,
                updatedAt: 2,
              ),
            );

        await push.pushFolderDelete(id);

        // Folder gone server-side + locally; the contained chat survived.
        check(server.getFolders().where((f) => f['id'] == id)).isEmpty();
        check(server.getChatById('kept')).isNotNull();
        check(server.getChatById('kept')!['folder_id']).isNull();
        check((await db.select(db.folders).get()).where((f) => f.id == id))
            .isEmpty();
      },
    );

    test('folder delete purges parked outbox ops for the folder', () async {
      final created = server.createFolder(name: 'Parked');
      final id = created['id'] as String;
      await db
          .into(db.folders)
          .insert(
            FoldersCompanion.insert(
              id: id,
              name: 'Parked',
              createdAt: 1,
              updatedAt: 2,
              deleted: const Value(true),
              dirty: const Value(true),
            ),
          );
      await seedParkedFolderOp(db, id);

      await push.pushFolderDelete(id);

      check(await db.foldersDao.getFolder(id)).isNull();
      check(await outboxOpsForChat(db, id)).isEmpty();
    });

    test(
      'folder delete treats an already-gone server folder as success',
      () async {
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: 'missing-folder',
                name: 'Missing',
                createdAt: 1,
                updatedAt: 2,
                deleted: const Value(true),
                dirty: const Value(true),
              ),
            );

        await push.pushFolderDelete('missing-folder');

        check(await db.foldersDao.getFolder('missing-folder')).isNull();
      },
    );
  });
}

class _RecordingChatLocks extends ConversationLocks {
  final List<String> keys = <String>[];
  final List<Set<String>> activeSnapshots = <Set<String>>[];
  final Set<String> _active = <String>{};

  @override
  Future<T> runExclusive<T>(String chatId, Future<T> Function() action) {
    keys.add(chatId);
    return super.runExclusive(chatId, () async {
      _active.add(chatId);
      activeSnapshots.add(Set<String>.of(_active));
      try {
        return await action();
      } finally {
        _active.remove(chatId);
      }
    });
  }
}

/// ChatLocks exposes `isIdle`; helper keeps call sites tidy.
bool locksIdle(ChatLocks locks) => locks.isIdle;
