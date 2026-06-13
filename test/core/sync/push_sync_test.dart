import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/push_sync.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

class FakeSyncClock implements SyncClock {
  int now = 0;
  @override
  int nowEpochSeconds() => now;
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
  await db.into(db.chats).insert(
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
    await db.into(db.messages).insert(
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

void main() {
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late AppDatabase db;
  late ChatLocks chatLocks;
  late ChatLocks folderLocks;
  late IdRemapper remapper;
  late FakeSyncClock clock;
  late PushSync push;

  setUp(() {
    server = FakeOpenWebUiServer(nowEpochSeconds: () => 7000);
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    chatLocks = ChatLocks();
    folderLocks = ChatLocks();
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

    test('returns null when the chat was deleted before the push ran',
        () async {
      check(await push.pushCreateChat('local:ghost')).isNull();
      check(client.createChatCalls).equals(0);
    });

    test(
        're-run with an already-remapped (non-local) id does NOT POST a '
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
  });

  group('pushUpdateChat', () {
    test('pushes the FULL reconstructed blob (shallow-merge keeps it intact)',
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
      check((stored['chat'] as Map)['models'] as List)
          .deepEquals(['llama3']);

      // serverUpdatedAt stored, dirty cleared for chat + its messages.
      final chat = await db.chatsDao.getChat('srv-1');
      check(chat!.serverUpdatedAt).equals(7000);
      check(chat.dirty).isFalse();
      final msgs = await db.messagesDao.getForChat('srv-1');
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

      await check(push.pushUpdateChat('stub')).throws<StateError>();

      final stored = server.getChatById('stub')!;
      final history = (stored['chat'] as Map)['history'] as Map;
      final messages = history['messages'] as Map;
      check(messages.keys.toSet()).deepEquals({'server-old'});
      check((await db.chatsDao.getChat('stub'))!.dirty).isTrue();
    });

    test('respects the server shallow-merge + output->content re-derivation',
        () async {
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
      await db.into(db.chats).insert(
            ChatsCompanion.insert(
              id: 'srv-out',
              title: 'Title srv-out',
              currentMessageId: const Value('a1'),
              createdAt: 1,
              updatedAt: 2,
              dirty: const Value(true),
              bodySynced: const Value(true),
              blobMeta: Value(jsonEncode(<String, dynamic>{
                'v': 1,
                'blobHadTitle': true,
                'blobTitleValue': 'Title srv-out',
                'blobHadHistory': true,
                'historyHadMessages': true,
                'historyHadCurrentId': true,
                'historyExtra': <String, dynamic>{},
                'unmappableMessages': <String, dynamic>{},
              })),
            ),
          );
      await db.into(db.messages).insert(
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
        blob: {'title': 'p', 'history': {'messages': {}, 'currentId': null}},
        createdAt: 1,
        updatedAt: 2,
        pinned: false,
        archived: false,
      );
      // Local wants pinned=true, archived=true.
      await seedLocalChat(db, id: 'srv-pin', messageCount: 0, pinned: true,
          archived: true);

      await push.pushUpdateChat('srv-pin');

      final stored = server.getChatById('srv-pin')!;
      check(stored['pinned']).equals(true);
      check(stored['archived']).equals(true);
    });

    test('folder-move delta routes through the dedicated /folder endpoint',
        () async {
      server.seedFolder('srv-folder');
      server.seedChat(
        id: 'srv-mv',
        blob: {'title': 'm', 'history': {'messages': {}, 'currentId': null}},
        createdAt: 1,
        updatedAt: 2,
      );
      await seedLocalChat(db, id: 'srv-mv', messageCount: 0,
          folderId: 'srv-folder');

      await push.pushUpdateChat('srv-mv');

      check(server.getChatById('srv-mv')!['folder_id']).equals('srv-folder');
    });

    test('404 (chat gone) is non-fatal: logs and returns, no dirty cleared',
        () async {
      await seedLocalChat(db, id: 'absent', messageCount: 1, dirty: true);
      // No server chat seeded -> updateChat returns null (404).
      await push.pushUpdateChat('absent');
      // Dirty stays set (nothing confirmed).
      final chat = await db.chatsDao.getChat('absent');
      check(chat!.dirty).isTrue();
      check(chat.serverUpdatedAt).isNull();
    });

    test('skips a tombstoned chat (a deleteChat op will handle it)', () async {
      await db.into(db.chats).insert(
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
        blob: {'title': 'd', 'history': {'messages': {}, 'currentId': null}},
        createdAt: 1,
        updatedAt: 2,
      );
      await seedLocalChat(db, id: 'srv-del', messageCount: 2);

      await push.pushDeleteChat('srv-del');

      check(server.getChatById('srv-del')).isNull();
      check(await db.chatsDao.getChat('srv-del')).isNull();
      check(await db.messagesDao.getForChat('srv-del')).isEmpty();
    });

    test('404 (already gone) still purges local rows without throwing',
        () async {
      await seedLocalChat(db, id: 'srv-gone', messageCount: 1);
      // No server chat -> deleteChat returns false; purge proceeds.
      await push.pushDeleteChat('srv-gone');
      check(await db.chatsDao.getChat('srv-gone')).isNull();
    });

    test('terminal 403 propagates and leaves local rows intact', () async {
      server.seedChat(
        id: 'srv-perm',
        blob: {'title': 'p', 'history': {'messages': {}, 'currentId': null}},
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
    test('local folder create -> server create + remap + dirty clear',
        () async {
      const localId = 'local:fold';
      await db.into(db.folders).insert(
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
        'createIfAbsent': true,
      });

      // Local folder remapped to a server id; exactly one folder row, not
      // dirty.
      final folders = await db.select(db.folders).get();
      check(folders.length).equals(1);
      check(folders.single.id.startsWith('local:')).isFalse();
      check(folders.single.dirty).isFalse();
      check(server.getFolders().map((f) => f['name'])).contains('Work');
    });

    test('existing folder update pushes name + parent', () async {
      final created = server.createFolder(name: 'Old');
      final id = created['id'] as String;
      await db.into(db.folders).insert(
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

    test('existing folder update 404 returns without clearing dirty', () async {
      await db.into(db.folders).insert(
            FoldersCompanion.insert(
              id: 'missing-folder',
              name: 'Ghost',
              createdAt: 1,
              updatedAt: 2,
              dirty: const Value(true),
            ),
          );

      await push.pushFolderUpsert(<String, dynamic>{
        'folderId': 'missing-folder',
        'name': 'Ghost',
        'createIfAbsent': false,
      });

      final row = await db.foldersDao.getFolder('missing-folder');
      check(row).isNotNull();
      check(row!.dirty).isTrue();
    });

    test('folder delete uses delete_contents=false and purges the row',
        () async {
      final created = server.createFolder(name: 'Doomed');
      final id = created['id'] as String;
      // A chat inside the folder must survive (re-parented to root).
      server.seedChat(
        id: 'kept',
        blob: {'title': 'k', 'history': {'messages': {}, 'currentId': null}},
        createdAt: 1,
        updatedAt: 2,
        folderId: id,
      );
      await db.into(db.folders).insert(
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
    });

    test('folder delete treats an already-gone server folder as success',
        () async {
      await db.into(db.folders).insert(
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
    });
  });
}

/// ChatLocks exposes `isIdle`; helper keeps call sites tidy.
bool locksIdle(ChatLocks locks) => locks.isIdle;
