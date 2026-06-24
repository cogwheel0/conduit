import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/sync/backoff.dart';
import 'package:conduit/core/sync/chat_adapter.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/outbox_drainer.dart';
import 'package:conduit/core/sync/pull_sync.dart';
import 'package:conduit/core/sync/push_sync.dart';
import 'package:conduit/features/chat/services/request_completion_runner.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

/// Mutable epoch-seconds clock.
class _Clock implements SyncClock {
  _Clock(this.now);
  int now;
  @override
  int nowEpochSeconds() => now;
}

/// Records every completion the drainer drives (chatId + payload) and the
/// wall-order relative to push calls, so we can assert pull-then-push ordering
/// and that the create op runs BEFORE its dependent requestCompletion.
class _RecordingCompletion implements RequestCompletionRunner {
  _RecordingCompletion(this.log);
  final List<String> log;
  final List<String> ranChats = <String>[];
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];

  /// When set, the runner throws this on its next run (consumed once).
  Object? nextError;

  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    await Future<void>.delayed(Duration.zero);
    final err = nextError;
    if (err != null) {
      nextError = null;
      throw err;
    }
    ranChats.add(chatId);
    payloads.add(payload);
    log.add('completion:$chatId');
  }
}

/// FakeSyncApiClient subclass that logs createChat start order interleaved with
/// completion runs (same `log` list).
class _LoggingClient extends FakeSyncApiClient {
  _LoggingClient(super.server, this._log);
  final List<String> _log;

  @override
  Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> chatBlob, {
    String? folderId,
  }) async {
    _log.add('createChat');
    return super.createChat(chatBlob, folderId: folderId);
  }
}

ChatRows _localChatRows(String localId, String userId, String asstId) {
  return ChatBlobMapper.blobToRows(
    chatId: localId,
    blob: <String, dynamic>{
      'title': 'Offline send',
      'history': <String, dynamic>{
        'currentId': asstId,
        'messages': <String, dynamic>{
          userId: <String, dynamic>{
            'id': userId,
            'parentId': null,
            'childrenIds': <String>[asstId],
            'role': 'user',
            'content': 'hello',
            'timestamp': 1000,
          },
          asstId: <String, dynamic>{
            'id': asstId,
            'parentId': userId,
            'childrenIds': <String>[],
            'role': 'assistant',
            'content': '',
            'timestamp': 1000,
          },
        },
      },
    },
    title: 'Offline send',
    createdAt: 1000,
    updatedAt: 1000,
  );
}

void main() {
  late AppDatabase db;
  late OutboxDao dao;
  late FakeOpenWebUiServer server;
  late _LoggingClient client;
  late ConversationLocks chatLocks;
  late FolderLocks folderLocks;
  late IdRemapper remapper;
  late PushSync push;
  late _Clock clock;
  late List<String> log;
  late _RecordingCompletion completion;
  var online = true;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    dao = db.outboxDao;
    server = FakeOpenWebUiServer();
    log = <String>[];
    client = _LoggingClient(server, log);
    chatLocks = ConversationLocks();
    folderLocks = FolderLocks();
    clock = _Clock(1000);
    remapper = IdRemapper(db);
    push = PushSync(
      client: client,
      db: db,
      chatLocks: chatLocks,
      folderLocks: folderLocks,
      clock: clock,
      remapper: remapper,
    );
    completion = _RecordingCompletion(log);
    online = true;
  });

  tearDown(() async {
    await remapper.dispose();
    await db.close();
  });

  OutboxDrainer buildDrainer() => OutboxDrainer(
    db: db,
    clock: clock,
    backoff: Backoff(jitter: () => 0.0),
    isOnline: () => online,
    completion: completion,
    adapters: [
      ChatAdapter(
        pull: PullSync(
          client: client,
          db: db,
          locks: chatLocks,
          remapper: remapper,
        ),
        push: push,
      ),
    ],
  );

  group('drain -> completion ordering (offline send create+complete)', () {
    test(
      'createChat runs BEFORE its dependent requestCompletion, which the seam '
      'runs with the remapped server id',
      () async {
        const localId = 'local:send1';
        const userId = 'u1';
        const asstId = 'a1';
        final rows = _localChatRows(localId, userId, asstId);
        final hash = createChatContentHash(rows);

        await chatLocks.runExclusive(localId, () async {
          await db.chatsDao.insertLocalChatWithCreateOp(
            chat: rows.chat,
            messages: rows.messages,
            blobRows: rows,
            contentHash: hash,
            completion: const RequestCompletionPayload(
              assistantMessageId: asstId,
              model: 'm',
              toolIds: <String>[],
            ),
          );
        });

        // Two ops enqueued: createChat then requestCompletion (seq order).
        check(await dao.pendingForChat(localId)).length.equals(2);

        await buildDrainer().drain();

        // The remapped server id is the only non-local chat row now.
        final chats = await db.select(db.chats).get();
        final serverId = chats
            .map((c) => c.id)
            .firstWhere((id) => !id.startsWith('local:'));

        // createChat was driven before the completion ran (W ordering).
        check(log).deepEquals(['createChat', 'completion:$serverId']);

        // The completion ran exactly once.
        check(completion.ranChats).length.equals(1);
        // It received the SERVER id (the remap repointed the op's chat_id from
        // local:<uuid> to the server id inside the §7.3 tx).
        check(completion.ranChats.single.startsWith('local:')).isFalse();
        // Payload carried the queued assistantMessageId (R8 anti-desync).
        check(completion.payloads.single['assistantMessageId']).equals(asstId);

        // Both ops are gone (createChat done + remapped, completion done).
        check(await dao.pendingForChat(localId)).isEmpty();
        check(await dao.pendingForChat(serverId)).isEmpty();
      },
    );

    test(
      'a CompletionBusyException defers (stays pending) without parking',
      () async {
        // Seed a server chat with a standalone requestCompletion op (no create
        // dependency) so the only thing the drainer does is run the completion.
        const chatId = 'cbusy';
        server.seedChat(
          id: chatId,
          blob: {
            'title': 'T',
            'history': {
              'messages': {
                'm1': {
                  'id': 'm1',
                  'role': 'user',
                  'content': 'hi',
                  'parentId': null,
                  'childrenIds': <String>[],
                },
              },
              'currentId': 'm1',
            },
          },
          createdAt: 1,
          updatedAt: 1,
        );
        await db.transaction(
          () => dao.enqueue(
            kind: OutboxKind.requestCompletion,
            chatId: chatId,
            payload: const RequestCompletionPayload(
              assistantMessageId: 'aBusy',
              model: 'm',
            ).toJson(),
          ),
        );

        // First drain: the runner reports BUSY (a live stream owns the chat).
        completion.nextError = const CompletionBusyException(chatId);
        await buildDrainer().drain();

        // The op stays pending (a transient retry) and is NOT parked: the busy
        // exception is not terminal, so R5 deferral never burns the turn.
        final pending = await dao.pendingForChat(chatId);
        check(pending).length.equals(1);
        check(pending.single.status).equals('pending');
        check(pending.single.attempts).equals(0);
        check(pending.single.nextAttemptAt).equals(1001);
        check(await dao.watchParkedForChat(chatId).first).isEmpty();
        check(completion.ranChats).isEmpty();

        // Next drain (after the live stream finishes) runs it to completion.
        clock.now += 10;
        await buildDrainer().drain();
        check(completion.ranChats).deepEquals([chatId]);
        check(await dao.pendingForChat(chatId)).isEmpty();
      },
    );
  });
}
