import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/sync/chat_locks.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/outbox_drainer.dart';
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

/// Seeds a server-origin folder row (clean) directly.
Future<void> seedServerFolderRow(
  AppDatabase db, {
  required String id,
  String name = 'F',
  String? parentId,
  int updatedAt = 100,
}) async {
  await db
      .into(db.folders)
      .insert(
        FoldersCompanion.insert(
          id: id,
          name: name,
          parentId: Value(parentId),
          createdAt: 50,
          updatedAt: updatedAt,
          serverUpdatedAt: Value(updatedAt),
          dirty: const Value(false),
          deleted: const Value(false),
        ),
      );
}

Map<String, dynamic> rawFolder(
  String id, {
  String name = 'F',
  int updatedAt = 100,
}) => <String, dynamic>{
  'id': id,
  'name': name,
  'parent_id': null,
  'created_at': 50,
  'updated_at': updatedAt,
};

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
    clock = FakeSyncClock()..now = 7000;
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

  group('pull LWW is dirty-aware (§7.6)', () {
    test(
      'a dirty local folder edit is NOT clobbered by the server payload',
      () async {
        // Local edit pending push: name 'Local', dirty.
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: 'f1',
                name: 'Local',
                createdAt: 50,
                updatedAt: 100,
                serverUpdatedAt: const Value(100),
                dirty: const Value(true),
              ),
            );

        // Server still has the OLD name.
        await db.foldersDao.replaceServerFolders([
          rawFolder('f1', name: 'Server'),
        ]);

        final f1 = await db.foldersDao.getFolder('f1');
        check(f1!.name).equals('Local'); // local wins
        check(f1.dirty).isTrue();
      },
    );

    test(
      'a local tombstone is NOT resurrected by the server payload',
      () async {
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: 'f2',
                name: 'Gone',
                createdAt: 50,
                updatedAt: 100,
                deleted: const Value(true),
                dirty: const Value(true),
              ),
            );

        await db.foldersDao.replaceServerFolders([
          rawFolder('f2', name: 'Back'),
        ]);

        final f2 = await db.foldersDao.getFolder('f2');
        check(f2!.deleted).isTrue(); // not resurrected
        check(f2.name).equals('Gone');
      },
    );

    test(
      'a clean server-absent folder is purged (genuine server delete)',
      () async {
        await seedServerFolderRow(db, id: 'stale');
        // Payload no longer contains 'stale'.
        await db.foldersDao.replaceServerFolders([rawFolder('survivor')]);

        check(await db.foldersDao.getFolder('stale')).isNull();
        check(await db.foldersDao.getFolder('survivor')).isNotNull();
      },
    );

    test(
      'a dirty local-create absent from the server SURVIVES the purge',
      () async {
        // local:-create not yet pushed: dirty, absent from server.
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: 'local:new',
                name: 'Fresh',
                createdAt: 0,
                updatedAt: 0,
                serverUpdatedAt: const Value(null),
                dirty: const Value(true),
              ),
            );

        await db.foldersDao.replaceServerFolders([rawFolder('other')]);

        check(await db.foldersDao.getFolder('local:new')).isNotNull();
      },
    );

    test(
      'a clean server folder is upserted server-origin (dirty=false)',
      () async {
        await db.foldersDao.replaceServerFolders([rawFolder('s', name: 'Srv')]);
        final f = await db.foldersDao.getFolder('s');
        check(f!.name).equals('Srv');
        check(f.dirty).isFalse();
        check(f.serverUpdatedAt).equals(100);
      },
    );
  });

  group('FoldersDao local-mutation methods enqueue outbox ops', () {
    test(
      'upsertFolderWithOutbox (create) writes dirty row + folderUpsert op',
      () async {
        await folderLocks.runExclusive('local:fnew', () async {
          await db.foldersDao.upsertFolderWithOutbox(
            id: 'local:fnew',
            name: 'New Folder',
            createIfAbsent: true,
          );
        });

        final row = await db.foldersDao.getFolder('local:fnew');
        check(row!.dirty).isTrue();
        check(row.serverUpdatedAt).isNull();

        final ops = await db.outboxDao.pendingForChat('local:fnew');
        check(ops.length).equals(1);
        check(ops.single.kind).equals(OutboxKind.folderUpsert.name);
        final payload = jsonDecode(ops.single.payload) as Map<String, dynamic>;
        check(payload['createIfAbsent']).equals(true);
        check(payload['name']).equals('New Folder');
      },
    );

    test(
      'upsertFolderWithOutbox (edit) marks an existing folder dirty',
      () async {
        await seedServerFolderRow(db, id: 'f', name: 'Old');
        await folderLocks.runExclusive('f', () async {
          await db.foldersDao.upsertFolderWithOutbox(
            id: 'f',
            name: 'Renamed',
            createIfAbsent: false,
          );
        });
        final row = await db.foldersDao.getFolder('f');
        check(row!.name).equals('Renamed');
        check(row.dirty).isTrue();
        // serverUpdatedAt preserved (LWW gate keys off dirty, not the clock).
        check(row.serverUpdatedAt).equals(100);
      },
    );

    test(
      'upsertFolderWithOutbox preserves parent when edit omits parentId',
      () async {
        await seedServerFolderRow(db, id: 'f', name: 'Old', parentId: 'parent');
        await folderLocks.runExclusive('f', () async {
          await db.foldersDao.upsertFolderWithOutbox(
            id: 'f',
            name: 'Renamed',
            createIfAbsent: false,
          );
        });

        final row = await db.foldersDao.getFolder('f');
        check(row!.parentId).equals('parent');

        final ops = await db.outboxDao.pendingForChat('f');
        final payload = jsonDecode(ops.single.payload) as Map<String, dynamic>;
        check(payload.containsKey('parentId')).isFalse();
      },
    );

    test(
      'upsertFolderWithOutbox can explicitly move a folder to root',
      () async {
        await seedServerFolderRow(db, id: 'f', name: 'Old', parentId: 'parent');
        await folderLocks.runExclusive('f', () async {
          await db.foldersDao.upsertFolderWithOutbox(
            id: 'f',
            parentId: const Value(null),
            createIfAbsent: false,
          );
        });

        final row = await db.foldersDao.getFolder('f');
        check(row!.parentId).isNull();

        final ops = await db.outboxDao.pendingForChat('f');
        final payload = jsonDecode(ops.single.payload) as Map<String, dynamic>;
        check(payload.containsKey('parentId')).isTrue();
        check(payload['parentId']).isNull();
      },
    );

    test(
      'tombstoneFolderWithOutbox tombstones + enqueues folderDelete',
      () async {
        await seedServerFolderRow(db, id: 'f');
        await folderLocks.runExclusive('f', () async {
          await db.foldersDao.tombstoneFolderWithOutbox('f');
        });
        final row = await db.foldersDao.getFolder('f');
        check(row!.deleted).isTrue();
        check(row.dirty).isTrue();
        final ops = await db.outboxDao.pendingForChat('f');
        check(ops.single.kind).equals(OutboxKind.folderDelete.name);
      },
    );

    test(
      'tombstoneFolderWithOutbox drops an annihilated local create',
      () async {
        await folderLocks.runExclusive('local:fdelete', () async {
          await db.foldersDao.upsertFolderWithOutbox(
            id: 'local:fdelete',
            name: 'Delete Me',
            createIfAbsent: true,
          );
          check(
            (await db.outboxDao.pendingForChat(
              'local:fdelete',
            )).map((op) => op.kind),
          ).deepEquals([OutboxKind.folderUpsert.name]);

          await db.foldersDao.tombstoneFolderWithOutbox('local:fdelete');
        });

        check(await db.foldersDao.getFolder('local:fdelete')).isNull();
        check(await db.outboxDao.pendingForChat('local:fdelete')).isEmpty();
      },
    );

    test('dropLocalFolder removes a local create + its pending ops', () async {
      await folderLocks.runExclusive('local:f', () async {
        await db.foldersDao.upsertFolderWithOutbox(
          id: 'local:f',
          name: 'X',
          createIfAbsent: true,
        );
      });
      await folderLocks.runExclusive('local:f', () async {
        await db.foldersDao.dropLocalFolder('local:f');
      });
      check(await db.foldersDao.getFolder('local:f')).isNull();
      check(await db.outboxDao.pendingForChat('local:f')).isEmpty();
    });
  });

  group('pushFolderDelete uses delete_contents=false (§7.6 BINDING)', () {
    test('a contained chat is re-parented to root, NOT deleted', () async {
      server.seedFolder('folderX');
      server.seedChat(
        id: 'inside',
        blob: <String, dynamic>{'id': '', 'title': 'inside'},
        createdAt: 50,
        updatedAt: 100,
        folderId: 'folderX',
      );

      await folderLocks.runExclusive('folderX', () async {
        await db
            .into(db.folders)
            .insert(
              FoldersCompanion.insert(
                id: 'folderX',
                name: 'X',
                createdAt: 50,
                updatedAt: 100,
                deleted: const Value(true),
                dirty: const Value(true),
              ),
            );
      });

      await push.pushFolderDelete('folderX');

      // The contained chat survives (re-parented to root), proving
      // delete_contents=false reached the server.
      final chat = server.getChatById('inside');
      check(chat).isNotNull();
      check(chat!['folder_id']).isNull();
      // Local folder row purged after confirm.
      check(await db.foldersDao.getFolder('folderX')).isNull();
    });
  });

  group('folder-before-chat ordering (§7.6 non-negotiable 6)', () {
    test('pushUpdateChat does NOT send a local:-prefixed folder id; leaves the '
        'chat dirty and lets the drainer back off the existing op', () async {
      // A server chat whose folderId points at a still-local folder.
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'chat1',
              title: 'Chat',
              folderId: const Value('local:pendingFolder'),
              createdAt: 50,
              updatedAt: 100,
              serverUpdatedAt: const Value(100),
              dirty: const Value(true),
              bodySynced: const Value(true),
              rawExtra: const Value('{}'),
              blobMeta: Value(
                jsonEncode(<String, dynamic>{
                  'v': 1,
                  'blobHadTitle': true,
                  'blobTitleValue': 'Chat',
                  'blobHadHistory': true,
                  'historyHadMessages': true,
                  'historyHadCurrentId': false,
                  'historyExtra': <String, dynamic>{},
                  'unmappableMessages': <String, dynamic>{},
                }),
              ),
            ),
          );
      // Register the chat server-side (so updateChat finds it) at root.
      server.seedChat(
        id: 'chat1',
        blob: <String, dynamic>{'id': '', 'title': 'Chat'},
        createdAt: 50,
        updatedAt: 100,
      );

      await check(
        push.pushUpdateChat('chat1'),
      ).throws<OutboxDeferralException>();

      // No server write/move happens while the folder id is still local.
      check(client.updateChatCalls).equals(0);
      check(server.getChatById('chat1')!['folder_id']).isNull();
      // Chat stays dirty; when run through OutboxDrainer, the same op backs
      // off instead of completing and enqueueing a fresh immediate retry.
      final chat = await db.chatsDao.getChat('chat1');
      check(chat!.dirty).isTrue();
      check(await db.outboxDao.pendingForChat('chat1')).isEmpty();
    });

    test(
      'after the folder is remapped to a server id, pushUpdateChat sends the '
      'real folder id and clears dirty',
      () async {
        // Seed a real server folder + a server chat at root.
        server.seedFolder('serverFolder');
        server.seedChat(
          id: 'chat2',
          blob: <String, dynamic>{'id': '', 'title': 'Chat2'},
          createdAt: 50,
          updatedAt: 100,
        );
        await db
            .into(db.chats)
            .insert(
              ChatsCompanion.insert(
                id: 'chat2',
                title: 'Chat2',
                folderId: const Value('serverFolder'),
                createdAt: 50,
                updatedAt: 100,
                serverUpdatedAt: const Value(100),
                dirty: const Value(true),
                bodySynced: const Value(true),
                rawExtra: const Value('{}'),
                blobMeta: Value(
                  jsonEncode(<String, dynamic>{
                    'v': 1,
                    'blobHadTitle': true,
                    'blobTitleValue': 'Chat2',
                    'blobHadHistory': true,
                    'historyHadMessages': true,
                    'historyHadCurrentId': false,
                    'historyExtra': <String, dynamic>{},
                    'unmappableMessages': <String, dynamic>{},
                  }),
                ),
              ),
            );

        await push.pushUpdateChat('chat2');

        // The real folder id reached the server.
        check(server.getChatById('chat2')!['folder_id']).equals('serverFolder');
        final chat = await db.chatsDao.getChat('chat2');
        check(chat!.dirty).isFalse();
      },
    );
  });
}
