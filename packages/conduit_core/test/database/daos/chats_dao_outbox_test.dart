import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/models/chat_comparison.dart';
import 'package:conduit_core/sync/chat_merger.dart' show MergeOutcome;
import 'package:conduit_core/sync/id_remapper.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';

/// W1 — local-mutation ChatsDao methods that write rows AND their outbox op in
/// ONE transaction (REQ §7.2.1, R2).
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> seedServerChat(String id, {String? folderId}) async {
    final rows = ChatBlobMapper.blobToRows(
      chatId: id,
      title: 'Title $id',
      folderId: folderId,
      createdAt: 1,
      updatedAt: 1,
      blob: <String, dynamic>{
        'title': 'Title $id',
        'history': <String, dynamic>{
          'currentId': 'm1',
          'messages': <String, dynamic>{
            'm1': <String, dynamic>{
              'id': 'm1',
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'hello',
              'timestamp': 1,
            },
          },
        },
      },
    );
    await db.chatsDao.upsertServerChat(rows: rows);
  }

  ChatRows newLocalRows(String localId) {
    return ChatBlobMapper.blobToRows(
      chatId: localId,
      title: 'Hello there',
      createdAt: 100,
      updatedAt: 100,
      blob: <String, dynamic>{
        'title': 'Hello there',
        'history': <String, dynamic>{
          'currentId': 'a1',
          'messages': <String, dynamic>{
            'u1': <String, dynamic>{
              'id': 'u1',
              'parentId': null,
              'childrenIds': <String>['a1'],
              'role': 'user',
              'content': 'Hello there',
              'timestamp': 100,
            },
            'a1': <String, dynamic>{
              'id': 'a1',
              'parentId': 'u1',
              'childrenIds': <String>[],
              'role': 'assistant',
              'content': '',
              'timestamp': 100,
            },
          },
        },
      },
    );
  }

  Future<Map<String, dynamic>> rebuiltBlob(String chatId) async {
    final chat = (await db.chatsDao.getChat(chatId))!;
    final messages = await db.messagesDao.getForChat(chatId);
    return ChatBlobMapper.rowsToBlob(chatRowsFromDb(chat, messages));
  }

  group('updateEnvelopeWithOutbox', () {
    test('local edit sets dirty and enqueues an updateChat op', () async {
      await seedServerChat('c1');
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('Renamed'),
        enqueue: true,
      );

      final chat = await db.chatsDao.getChat('c1');
      check(chat!.title).equals('Renamed');
      check(chat.dirty).isTrue();
      final ops = await db.outboxDao.pendingForChat('c1');
      check(ops).length.equals(1);
      check(ops.single.kind).equals('updateChat');
    });

    test('enqueue:false (server-origin) writes rows but no op', () async {
      await seedServerChat('c1');
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        pinned: const Value(true),
        enqueue: false,
      );
      check((await db.chatsDao.getChat('c1'))!.pinned).isTrue();
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test('consecutive local updates coalesce to one op', () async {
      await seedServerChat('c1');
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('A'),
        enqueue: true,
      );
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('B'),
        enqueue: true,
      );
      check(await db.outboxDao.pendingForChat('c1')).length.equals(1);
    });
  });

  group('patchChatParamsWithOutbox', () {
    // A server chat whose blob carries saved params plus keys nothing in this
    // app edits, so a patch has plenty of siblings to damage.
    Map<String, dynamic> richBlob() => <String, dynamic>{
      'title': 'Rich',
      'models': <String>['model-a'],
      'params': <String, dynamic>{
        'temperature': 0.2,
        'top_p': 0.9,
        'system': 'Be brief.',
        'custom_params': <String, dynamic>{'k': 'v'},
      },
      'tags': <String>['t1'],
      'files': <Map<String, dynamic>>[],
      'future_envelope_key': <String, dynamic>{'x': 1},
      'history': <String, dynamic>{
        'currentId': 'm1',
        'messages': <String, dynamic>{
          'm1': <String, dynamic>{
            'id': 'm1',
            'parentId': null,
            'childrenIds': <String>[],
            'role': 'user',
            'content': 'hello',
            'timestamp': 1,
          },
        },
      },
    };

    Future<void> seedRich(String id, {String? folderId}) async {
      await db.chatsDao.upsertServerChat(
        rows: ChatBlobMapper.blobToRows(
          chatId: id,
          title: 'Rich',
          folderId: folderId,
          createdAt: 1,
          updatedAt: 1,
          blob: richBlob(),
        ),
      );
    }

    Future<Map<String, dynamic>> storedParams(String id) async {
      final raw = (await db.chatsDao.getChat(id))!.rawExtra;
      return (jsonDecode(raw) as Map<String, dynamic>)['params']
          as Map<String, dynamic>;
    }

    test('changes only the requested params; every sibling survives', () async {
      await seedRich('c1', folderId: 'folder-1');
      final before = await rebuiltBlob('c1');
      final beforeChat = (await db.chatsDao.getChat('c1'))!;

      final saved = await db.chatsDao.patchChatParamsWithOutbox(
        'c1',
        set: {'temperature': 0.9, 'seed': 7},
        remove: ['top_p'],
        updatedAt: 50,
      );

      check(saved).isNotNull().deepEquals({
        'temperature': 0.9,
        'system': 'Be brief.',
        'custom_params': {'k': 'v'},
        'seed': 7,
      });
      // The whole rebuilt blob equals the old one except for `params`.
      final after = await rebuiltBlob('c1');
      final expected = Map<String, dynamic>.of(before)..['params'] = saved;
      check(const DeepCollectionEquality().equals(after, expected)).isTrue();

      final chat = (await db.chatsDao.getChat('c1'))!;
      check(chat.folderId).equals('folder-1');
      check(chat.currentMessageId).equals(beforeChat.currentMessageId);
      check(chat.title).equals(beforeChat.title);
      check(chat.dirty).isTrue();
      check(chat.updatedAt).equals(50);
      final ops = await db.outboxDao.pendingForChat('c1');
      check(ops).length.equals(1);
      check(ops.single.kind).equals('updateChat');
    });

    test(
      'an explicit empty system and an explicit null are real values',
      () async {
        await seedRich('c1');

        await db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          set: {'system': '', 'reasoning_effort': null},
          updatedAt: 5,
        );

        final params = await storedParams('c1');
        check(params.containsKey('system')).isTrue();
        check(params['system']).equals('');
        check(params.containsKey('reasoning_effort')).isTrue();
        check(params['reasoning_effort']).isNull();
      },
    );

    test(
      'removing a key inherits again without touching hidden params',
      () async {
        await seedRich('c1');

        await db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          remove: ['system'],
          updatedAt: 5,
        );

        final params = await storedParams('c1');
        check(params.containsKey('system')).isFalse();
        check(params['custom_params'])
            .isA<Map<String, dynamic>>()
            .deepEquals({'k': 'v'});
        check(params['temperature']).equals(0.2);
      },
    );

    test(
      'a patch that changes nothing writes nothing and queues nothing',
      () async {
        await seedRich('c1');

        final saved = await db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          set: {'temperature': 0.2},
          remove: ['not-there'],
          updatedAt: 99,
        );

        check(saved).isNotNull();
        final chat = (await db.chatsDao.getChat('c1'))!;
        check(chat.dirty).isFalse();
        check(chat.updatedAt).equals(1);
        check(await db.outboxDao.pendingForChat('c1')).isEmpty();
      },
    );

    test('an absent or tombstoned chat is not written', () async {
      check(
        await db.chatsDao.patchChatParamsWithOutbox(
          'missing',
          set: {'seed': 1},
          updatedAt: 5,
        ),
      ).isNull();

      await seedRich('c1');
      await db.chatsDao.tombstoneWithOutbox('c1');
      final opsAfterTombstone = (await db.outboxDao.pendingForChat('c1'))
          .length;
      check(
        await db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          set: {'seed': 1},
          updatedAt: 5,
        ),
      ).isNull();
      check(await db.outboxDao.pendingForChat('c1')).length
          .equals(opsAfterTombstone);
    });

    test(
      'a chat that never had params gains them without losing siblings',
      () async {
        await seedServerChat('c1');
        final before = await rebuiltBlob('c1');

        await db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          set: {'temperature': 0.5},
          updatedAt: 5,
        );

        final after = await rebuiltBlob('c1');
        check(
          const DeepCollectionEquality().equals(
            after,
            Map<String, dynamic>.of(before)..['params'] = {'temperature': 0.5},
          ),
        ).isTrue();
      },
    );

    test(
      'a stored non-object params is kept unless there is something to write',
      () async {
        await seedRich('c1');
        await (db.update(db.chats)..where((t) => t.id.equals('c1'))).write(
          ChatsCompanion(
            rawExtra: Value(
              jsonEncode(<String, dynamic>{
                'params': 'corrupt',
                'tags': <String>['t1'],
              }),
            ),
          ),
        );

        await db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          remove: ['system'],
          updatedAt: 5,
        );
        check(jsonDecode((await db.chatsDao.getChat('c1'))!.rawExtra))
            .isA<Map<String, dynamic>>()
            .deepEquals({
              'params': 'corrupt',
              'tags': ['t1'],
            });
        check(await db.outboxDao.pendingForChat('c1')).isEmpty();

        await db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          set: {'seed': 3},
          updatedAt: 6,
        );
        check(jsonDecode((await db.chatsDao.getChat('c1'))!.rawExtra))
            .isA<Map<String, dynamic>>()
            .deepEquals({
              'params': {'seed': 3},
              'tags': ['t1'],
            });
      },
    );

    test('an unreadable envelope is never overwritten', () async {
      await seedRich('c1');
      await (db.update(db.chats)..where((t) => t.id.equals('c1'))).write(
        const ChatsCompanion(rawExtra: Value('not json at all')),
      );

      await check(
        db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          set: {'seed': 3},
          updatedAt: 6,
        ),
      ).throws<StateError>();

      final chat = (await db.chatsDao.getChat('c1'))!;
      check(chat.rawExtra).equals('not json at all');
      check(chat.dirty).isFalse();
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test('a failed op write rolls the settings write back', () async {
      await seedRich('c1');
      final before = (await db.chatsDao.getChat('c1'))!;
      await db.customStatement(
        'CREATE TRIGGER fail_outbox_insert BEFORE INSERT ON outbox_ops '
        "BEGIN SELECT RAISE(ABORT, 'outbox unavailable'); END",
      );

      await check(
        db.chatsDao.patchChatParamsWithOutbox(
          'c1',
          set: {'temperature': 1.5},
          updatedAt: 77,
        ),
      ).throws<Object>();

      final after = (await db.chatsDao.getChat('c1'))!;
      check(after.rawExtra).equals(before.rawExtra);
      check(after.dirty).isFalse();
      check(after.updatedAt).equals(before.updatedAt);
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test(
      'an edit to a chat awaiting its create folds into that create',
      () async {
        final rows = newLocalRows('local:chat-1');
        final hash = createChatContentHash(rows);
        await db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: hash,
        );

        await db.chatsDao.patchChatParamsWithOutbox(
          'local:chat-1',
          set: {'system': 'Offline prompt'},
          updatedAt: 200,
        );

        final ops = await db.outboxDao.pendingForChat('local:chat-1');
        check(ops).length.equals(1);
        check(ops.single.kind).equals('createChat');
        // The create now fingerprints the rows it will actually POST.
        check(ops.single.contentHash).isNotNull().not((it) => it.equals(hash));
        final blob = await rebuiltBlob('local:chat-1');
        check(blob['params'])
            .isA<Map<String, dynamic>>()
            .deepEquals({'system': 'Offline prompt'});
      },
    );
  });

  group('a pull after a local change to a chat another client also changed', () {
    // The chat as the server holds it after another client rewrote its params.
    ChatRows serverCopy({
      required int updatedAt,
      required Map<String, dynamic> params,
    }) => ChatBlobMapper.blobToRows(
      chatId: 'c1',
      title: 'Title c1',
      createdAt: 1,
      updatedAt: updatedAt,
      blob: <String, dynamic>{
        'title': 'Title c1',
        'params': params,
        'models': <String>['from-server'],
        'history': <String, dynamic>{
          'currentId': 'm1',
          'messages': <String, dynamic>{
            'm1': <String, dynamic>{
              'id': 'm1',
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'hello',
              'timestamp': 1,
            },
          },
        },
      },
    );

    Future<void> seedWithParams() async {
      await db.chatsDao.upsertServerChat(
        rows: serverCopy(updatedAt: 1, params: {'temperature': 0.2}),
      );
    }

    test(
      'a title-only local change does not overwrite the other client\'s params',
      () async {
        await seedWithParams();
        await db.chatsDao.updateEnvelopeWithOutbox(
          'c1',
          title: const Value('Renamed offline'),
          enqueue: true,
        );

        final result = await db.chatsDao.mergeServerChat(
          server: serverCopy(updatedAt: 5, params: {'temperature': 0.9}),
        );

        check(result.outcome).equals(MergeOutcome.threeWay);
        check((await db.chatsDao.getChat('c1'))!.title)
            .equals('Renamed offline');
        check(await db.chatsDao.getChatParams('c1'))
            .isNotNull()
            .deepEquals({'temperature': 0.9});
      },
    );

    test('a pending params edit survives the same pull', () async {
      await seedWithParams();
      await db.chatsDao.patchChatParamsWithOutbox(
        'c1',
        set: {'seed': 7},
        updatedAt: 3,
      );

      final result = await db.chatsDao.mergeServerChat(
        server: serverCopy(updatedAt: 5, params: {'temperature': 0.9}),
      );

      check(result.outcome).equals(MergeOutcome.threeWay);
      check(await db.chatsDao.getChatParams('c1'))
          .isNotNull()
          .deepEquals({'temperature': 0.2, 'seed': 7});
      // The rest of the envelope still comes from the server.
      final extra =
          jsonDecode((await db.chatsDao.getChat('c1'))!.rawExtra)
              as Map<String, dynamic>;
      check(extra['models']).isA<List>().deepEquals(['from-server']);
      // And the edit is still on its way to the server.
      check(await db.outboxDao.pendingForChat('c1')).length.equals(1);
    });

    test('a title change made after the params edit does not lose it', () async {
      await seedWithParams();
      await db.chatsDao.patchChatParamsWithOutbox(
        'c1',
        set: {'seed': 7},
        updatedAt: 3,
      );
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('Renamed too'),
        enqueue: true,
      );

      await db.chatsDao.mergeServerChat(
        server: serverCopy(updatedAt: 5, params: {'temperature': 0.9}),
      );

      check(await db.chatsDao.getChatParams('c1'))
          .isNotNull()
          .deepEquals({'temperature': 0.2, 'seed': 7});
    });

    test('once the edit is pushed a later pull takes the server\'s', () async {
      await seedWithParams();
      await db.chatsDao.patchChatParamsWithOutbox(
        'c1',
        set: {'seed': 7},
        updatedAt: 3,
      );
      // The drainer confirmed the push and removed the op.
      for (final op in await db.outboxDao.pendingForChat('c1')) {
        await db.outboxDao.markDone(op.seq);
      }
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('Renamed later'),
        enqueue: true,
      );

      await db.chatsDao.mergeServerChat(
        server: serverCopy(updatedAt: 5, params: {'temperature': 0.9}),
      );

      check(await db.chatsDao.getChatParams('c1'))
          .isNotNull()
          .deepEquals({'temperature': 0.9});
    });
  });

  group('patchChatCurrentMessageWithOutbox', () {
    // u1 has two answers; the server's active leaf starts on the first.
    ChatRows serverCopy({
      required int updatedAt,
      required String currentId,
      String title = 'Title c1',
      bool withSecondAnswer = true,
      bool withCurrentId = true,
    }) => ChatBlobMapper.blobToRows(
      chatId: 'c1',
      title: title,
      createdAt: 1,
      updatedAt: updatedAt,
      blob: <String, dynamic>{
        'title': title,
        'params': <String, dynamic>{'temperature': 0.2},
        'futureEnvelopeKey': <String, dynamic>{'kept': true},
        'history': <String, dynamic>{
          'messages': <String, dynamic>{
            'u1': <String, dynamic>{
              'id': 'u1',
              'parentId': null,
              'childrenIds': <String>['a1', if (withSecondAnswer) 'a2'],
              'role': 'user',
              'content': 'hello',
              'timestamp': 1,
            },
            'a1': <String, dynamic>{
              'id': 'a1',
              'parentId': 'u1',
              'childrenIds': <String>[],
              'role': 'assistant',
              'content': 'first',
              'timestamp': 2,
              'futureMessageKey': 7,
            },
            if (withSecondAnswer)
              'a2': <String, dynamic>{
                'id': 'a2',
                'parentId': 'u1',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': 'second',
                'timestamp': 3,
              },
          },
          if (withCurrentId) 'currentId': currentId,
        },
      },
    );

    Future<void> seed({bool withCurrentId = true}) => db.chatsDao.upsertServerChat(
      rows: serverCopy(
        updatedAt: 1,
        currentId: 'a2',
        withCurrentId: withCurrentId,
      ),
    );

    Future<Map<String, String>> payloads() async => {
      for (final m in await db.messagesDao.getForChat('c1')) m.id: m.payload,
    };

    test('writes only the leaf, marks the chat dirty and queues one op', () async {
      await seed();
      final before = await payloads();
      final envelopeBefore = (await db.chatsDao.getChat('c1'))!.rawExtra;

      final written = await db.chatsDao.patchChatCurrentMessageWithOutbox(
        'c1',
        'a1',
        updatedAt: 9,
      );

      check(written).equals(true);
      final chat = (await db.chatsDao.getChat('c1'))!;
      check(chat.currentMessageId).equals('a1');
      check(chat.dirty).isTrue();
      check(chat.updatedAt).equals(9);
      check(chat.rawExtra).equals(envelopeBefore);
      check(await payloads()).deepEquals(before);
      check((await db.messagesDao.getForChat('c1')).where((m) => m.dirty))
          .isEmpty();
      final ops = await db.outboxDao.pendingForChat('c1');
      check(ops).length.equals(1);
      check(jsonDecode(ops.single.payload) as Map)
          .deepEquals({kUpdateChatBranchEditKey: true});
    });

    test('is a no-op when the leaf is already current, or cannot be written', () async {
      await seed();

      check(
        await db.chatsDao.patchChatCurrentMessageWithOutbox(
          'c1',
          'a2',
          updatedAt: 9,
        ),
      ).equals(false);
      check(
        await db.chatsDao.patchChatCurrentMessageWithOutbox(
          'c1',
          'ghost',
          updatedAt: 9,
        ),
      ).isNull();
      check(
        await db.chatsDao.patchChatCurrentMessageWithOutbox(
          'absent',
          'a1',
          updatedAt: 9,
        ),
      ).isNull();
      check((await db.chatsDao.getChat('c1'))!.dirty).isFalse();
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
    });

    test('a tombstoned chat takes no choice', () async {
      await seed();
      await db.chatsDao.tombstoneWithOutbox('c1');

      check(
        await db.chatsDao.patchChatCurrentMessageWithOutbox(
          'c1',
          'a1',
          updatedAt: 9,
        ),
      ).isNull();
    });

    test('the choice is pushed even when the blob never had a currentId', () async {
      await seed(withCurrentId: false);

      await db.chatsDao.patchChatCurrentMessageWithOutbox(
        'c1',
        'a1',
        updatedAt: 9,
      );

      check(((await rebuiltBlob('c1'))['history'] as Map)['currentId'])
          .equals('a1');
    });

    test('a pending branch choice survives a newer remote copy', () async {
      await seed();
      await db.chatsDao.patchChatCurrentMessageWithOutbox(
        'c1',
        'a1',
        updatedAt: 3,
      );

      // Another client answered again, so the server leaf is a new message.
      final result = await db.chatsDao.mergeServerChat(
        server: serverCopy(updatedAt: 5, currentId: 'a2'),
      );

      check(result.outcome).equals(MergeOutcome.threeWay);
      check(result.mustPush).isTrue();
      final chat = (await db.chatsDao.getChat('c1'))!;
      check(chat.currentMessageId).equals('a1');
      check(chat.dirty).isTrue();
      // Every alternative and unknown key is kept, none became dirty.
      check((await db.messagesDao.getForChat('c1')).map((m) => m.id))
          .unorderedEquals(['u1', 'a1', 'a2']);
      check((await db.messagesDao.getForChat('c1')).where((m) => m.dirty))
          .isEmpty();
      check((jsonDecode((await db.messagesDao.getForChat('c1')).firstWhere(
        (m) => m.id == 'a1',
      ).payload) as Map)['futureMessageKey']).equals(7);
      check(((await rebuiltBlob('c1'))['history'] as Map)['currentId'])
          .equals('a1');
      // And it is still on its way to the server.
      final ops = await db.outboxDao.pendingForChat('c1');
      check(ops).length.equals(1);
      check(await db.outboxDao.hasPendingBranchEdit('c1')).isTrue();
    });

    test('a title-only change accepts the remote leaf', () async {
      await seed();
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('Renamed offline'),
        enqueue: true,
      );

      final result = await db.chatsDao.mergeServerChat(
        server: serverCopy(updatedAt: 5, currentId: 'a1'),
      );

      check(result.outcome).equals(MergeOutcome.threeWay);
      final chat = (await db.chatsDao.getChat('c1'))!;
      check(chat.title).equals('Renamed offline');
      check(chat.currentMessageId).equals('a1');
      check((await db.messagesDao.getForChat('c1')).where((m) => m.dirty))
          .isEmpty();
    });

    test('a title change after the choice does not lose it', () async {
      await seed();
      await db.chatsDao.patchChatCurrentMessageWithOutbox(
        'c1',
        'a1',
        updatedAt: 3,
      );
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('Renamed too'),
        enqueue: true,
      );

      await db.chatsDao.mergeServerChat(
        server: serverCopy(updatedAt: 5, currentId: 'a2'),
      );

      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('a1');
      check(await db.outboxDao.hasPendingBranchEdit('c1')).isTrue();
    });

    test('once the choice is pushed a later pull takes the server\'s leaf', () async {
      await seed();
      await db.chatsDao.patchChatCurrentMessageWithOutbox(
        'c1',
        'a1',
        updatedAt: 3,
      );
      // The drainer confirmed the push and removed the op.
      for (final op in await db.outboxDao.pendingForChat('c1')) {
        await db.outboxDao.markDone(op.seq);
      }
      await db.chatsDao.updateEnvelopeWithOutbox(
        'c1',
        title: const Value('Renamed later'),
        enqueue: true,
      );

      await db.chatsDao.mergeServerChat(
        server: serverCopy(updatedAt: 5, currentId: 'a2'),
      );

      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('a2');
    });

    test('a branch choice and a params edit keep both pieces of evidence', () async {
      await seed();
      await db.chatsDao.patchChatParamsWithOutbox(
        'c1',
        set: {'seed': 7},
        updatedAt: 2,
      );
      await db.chatsDao.patchChatCurrentMessageWithOutbox(
        'c1',
        'a1',
        updatedAt: 3,
      );

      final ops = await db.outboxDao.pendingForChat('c1');
      check(ops).length.equals(1);
      check(jsonDecode(ops.single.payload) as Map).deepEquals({
        kUpdateChatParamsEditKey: true,
        kUpdateChatBranchEditKey: true,
      });

      await db.chatsDao.mergeServerChat(
        server: serverCopy(updatedAt: 5, currentId: 'a2'),
      );

      final chat = (await db.chatsDao.getChat('c1'))!;
      check(chat.currentMessageId).equals('a1');
      check(await db.chatsDao.getChatParams('c1'))
          .isNotNull()
          .deepEquals({'temperature': 0.2, 'seed': 7});
    });

    test('a branch choice does not make params look edited', () async {
      await seed();
      await db.chatsDao.patchChatCurrentMessageWithOutbox(
        'c1',
        'a1',
        updatedAt: 3,
      );

      await db.chatsDao.mergeServerChat(
        server: ChatBlobMapper.blobToRows(
          chatId: 'c1',
          title: 'Title c1',
          createdAt: 1,
          updatedAt: 5,
          blob: <String, dynamic>{
            'title': 'Title c1',
            'params': <String, dynamic>{'temperature': 0.9},
            'history': <String, dynamic>{
              'currentId': 'a2',
              'messages': <String, dynamic>{
                'u1': <String, dynamic>{
                  'id': 'u1',
                  'parentId': null,
                  'childrenIds': <String>['a1', 'a2'],
                  'role': 'user',
                  'content': 'hello',
                  'timestamp': 1,
                },
                'a1': <String, dynamic>{
                  'id': 'a1',
                  'parentId': 'u1',
                  'childrenIds': <String>[],
                  'role': 'assistant',
                  'content': 'first',
                  'timestamp': 2,
                },
                'a2': <String, dynamic>{
                  'id': 'a2',
                  'parentId': 'u1',
                  'childrenIds': <String>[],
                  'role': 'assistant',
                  'content': 'second',
                  'timestamp': 3,
                },
              },
            },
          },
        ),
      );

      // The other client's newer params are taken; only the leaf was ours.
      check(await db.chatsDao.getChatParams('c1'))
          .isNotNull()
          .deepEquals({'temperature': 0.9});
      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('a1');
    });
  });

  group('getChatParams', () {
    test(
      'reads one chat\'s params, empty when it has none, null when absent',
      () async {
        await db.chatsDao.upsertServerChat(
          rows: ChatBlobMapper.blobToRows(
            chatId: 'c1',
            title: 'T',
            createdAt: 1,
            updatedAt: 1,
            blob: <String, dynamic>{
              'title': 'T',
              'params': <String, dynamic>{'seed': 4},
              'history': <String, dynamic>{
                'currentId': null,
                'messages': <String, dynamic>{},
              },
            },
          ),
        );
        await seedServerChat('c2');

        check(await db.chatsDao.getChatParams('c1'))
            .isNotNull()
            .deepEquals({'seed': 4});
        check(await db.chatsDao.getChatParams('c2')).isNotNull().isEmpty();
        check(await db.chatsDao.getChatParams('nope')).isNull();
      },
    );
  });

  group('tombstoneWithOutbox', () {
    test('tombstones (not hard-delete) and enqueues deleteChat', () async {
      await seedServerChat('c1');
      await db.chatsDao.tombstoneWithOutbox('c1');

      final chat = await db.chatsDao.getChat('c1');
      check(chat).isNotNull();
      check(chat!.deleted).isTrue();
      check(chat.dirty).isTrue();
      // Rows survive (drainer purges after server confirm).
      check(await db.messagesDao.getForChat('c1')).isNotEmpty();
      final ops = await db.outboxDao.pendingForChat('c1');
      check(ops.single.kind).equals('deleteChat');
    });

    test('hard-deletes a local create when create/delete annihilate', () async {
      const localId = 'local:delete-me';
      final rows = newLocalRows(localId);
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: 'hash-delete-me',
        completion: const RequestCompletionPayload(
          assistantMessageId: 'a1',
          model: 'gpt',
          toolIds: <String>[],
        ),
      );
      check((await db.outboxDao.pendingForChat(localId)).map((op) => op.kind))
          .deepEquals(['createChat', 'requestCompletion']);
      check(await db.messagesDao.getForChat(localId)).isNotEmpty();

      await db.chatsDao.tombstoneWithOutbox(localId);

      check(await db.chatsDao.getChat(localId)).isNull();
      check(await db.messagesDao.getForChat(localId)).isEmpty();
      check(await db.outboxDao.pendingForChat(localId)).isEmpty();
    });
  });

  group('dropLocalChat', () {
    test(
      'hard-deletes the row and its pending ops, no deleteChat op',
      () async {
        const localId = 'local:x';
        final rows = newLocalRows(localId);
        await db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: 'h',
        );
        check(await db.outboxDao.pendingForChat(localId)).isNotEmpty();

        await db.chatsDao.dropLocalChat(localId);

        check(await db.chatsDao.getChat(localId)).isNull();
        check(await db.messagesDao.getForChat(localId)).isEmpty();
        check(await db.outboxDao.pendingForChat(localId)).isEmpty();
      },
    );
  });

  group('insertLocalChatWithCreateOp', () {
    test('writes local chat + messages dirty, createChat then completion op', () async {
      const localId = 'local:new';
      final rows = newLocalRows(localId);
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: 'hash-1',
        completion: const RequestCompletionPayload(
          assistantMessageId: 'a1',
          model: 'gpt',
          toolIds: <String>['tool-a'],
          filterIds: <String>['filter-a'],
          terminalId: 'terminal-a',
          enableWebSearch: true,
          enableImageGeneration: true,
        ),
      );

      final chat = await db.chatsDao.getChat(localId);
      check(chat!.dirty).isTrue();
      check(chat.bodySynced).isTrue();
      check(chat.serverUpdatedAt).isNull();
      final msgs = await db.messagesDao.getForChat(localId);
      check(msgs.length).equals(2);
      check(msgs.every((m) => m.dirty)).isTrue();

      final ops = await db.outboxDao.pendingForChat(localId);
      check(ops.length).equals(2);
      // createChat seq < requestCompletion seq (drainer creates+remaps first).
      check(ops[0].kind).equals('createChat');
      check(ops[0].contentHash).equals('hash-1');
      check(ops[1].kind).equals('requestCompletion');
      check(ops[1].seq).isGreaterThan(ops[0].seq);
      final completionPayload = RequestCompletionPayload.fromJson(
        jsonDecode(ops[1].payload) as Map<String, dynamic>,
      );
      check(completionPayload.toolIds).deepEquals(['tool-a']);
      check(completionPayload.filterIds).deepEquals(['filter-a']);
      check(completionPayload.terminalId).equals('terminal-a');
      check(completionPayload.enableWebSearch).isTrue();
      check(completionPayload.enableImageGeneration).isTrue();
    });

    test('no completion payload enqueues only createChat', () async {
      const localId = 'local:nocomp';
      final rows = newLocalRows(localId);
      await db.chatsDao.insertLocalChatWithCreateOp(
        chat: rows.chat,
        messages: rows.messages,
        blobRows: rows,
        contentHash: 'h2',
      );
      final ops = await db.outboxDao.pendingForChat(localId);
      check(ops.length).equals(1);
      check(ops.single.kind).equals('createChat');
    });
  });

  group('appendMessagesWithUpdateOp', () {
    test(
      'appends rows dirty, updates envelope, enqueues update + completion',
      () async {
        await seedServerChat('c1');
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: 'c1',
          currentMessageId: 'a2',
          updatedAt: 500,
          messages: <MessageRowData>[
            MessageRowData(
              id: 'u2',
              chatId: 'c1',
              parentId: 'm1',
              role: 'user',
              content: 'next',
              createdAt: 400,
              orderIndex: 0,
              payload: const <String, dynamic>{
                'id': 'u2',
                'parentId': 'm1',
                'childrenIds': <String>['a2'],
                'role': 'user',
                'content': 'next',
                'metadata': <String, dynamic>{
                  'childrenIds': <String>['a2'],
                },
              },
            ),
            MessageRowData(
              id: 'a2',
              chatId: 'c1',
              parentId: 'u2',
              role: 'assistant',
              content: '',
              createdAt: 401,
              orderIndex: 0,
              payload: const <String, dynamic>{
                'id': 'a2',
                'parentId': 'u2',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': '',
              },
            ),
          ],
          enqueueCompletion: true,
          completion: const RequestCompletionPayload(
            assistantMessageId: 'a2',
            model: 'gpt',
          ),
        );

        final chat = await db.chatsDao.getChat('c1');
        check(chat!.dirty).isTrue();
        check(chat.currentMessageId).equals('a2');
        check(chat.updatedAt).equals(500);

        final msgs = await db.messagesDao.getForChat('c1');
        check(msgs.map((m) => m.id).toSet()).deepEquals({'m1', 'u2', 'a2'});
        // New rows got distinct orderIndex above the existing max (0 -> 1, 2).
        final u2 = msgs.firstWhere((m) => m.id == 'u2');
        final a2 = msgs.firstWhere((m) => m.id == 'a2');
        check(u2.orderIndex).not((it) => it.equals(a2.orderIndex));
        check(u2.dirty).isTrue();
        check(a2.dirty).isTrue();

        final ops = await db.outboxDao.pendingForChat('c1');
        check(ops.map((o) => o.kind).toList())
            .deepEquals(['updateChat', 'requestCompletion']);
      },
    );

    test(
      'cancelPendingCompletion removes empty assistant before update drains',
      () async {
        await seedServerChat('c1');
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: 'c1',
          currentMessageId: 'a2',
          updatedAt: 500,
          messages: <MessageRowData>[
            MessageRowData(
              id: 'u2',
              chatId: 'c1',
              parentId: 'm1',
              role: 'user',
              content: 'next',
              createdAt: 400,
              orderIndex: 0,
              payload: const <String, dynamic>{
                'id': 'u2',
                'parentId': 'm1',
                'childrenIds': <String>['a2'],
                'role': 'user',
                'content': 'next',
                'metadata': <String, dynamic>{
                  'childrenIds': <String>['a2'],
                },
              },
            ),
            MessageRowData(
              id: 'a2',
              chatId: 'c1',
              parentId: 'u2',
              role: 'assistant',
              content: '',
              createdAt: 401,
              orderIndex: 0,
              payload: const <String, dynamic>{
                'id': 'a2',
                'parentId': 'u2',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': '',
              },
            ),
          ],
          enqueueCompletion: true,
          completion: const RequestCompletionPayload(
            assistantMessageId: 'a2',
            model: 'gpt',
          ),
        );

        final removed = await db.chatsDao.cancelPendingCompletion('c1');

        check(removed).equals(1);
        final messages = await db.messagesDao.getForChat('c1');
        check(messages.map((m) => m.id).toSet()).deepEquals({'m1', 'u2'});
        check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('u2');
        check(messages.singleWhere((m) => m.id == 'u2').dirty).isTrue();
        final blob = await rebuiltBlob('c1');
        final history = blob['history'] as Map<String, dynamic>;
        final blobMessages = history['messages'] as Map<String, dynamic>;
        check(blobMessages.containsKey('a2')).isFalse();
        final parentPayload = blobMessages['u2'] as Map<String, dynamic>;
        check(parentPayload['childrenIds'] as List<dynamic>)
            .deepEquals(<String>[]);
        final metadata = parentPayload['metadata'] as Map<String, dynamic>;
        check(metadata['childrenIds'] as List<dynamic>).deepEquals(<String>[]);
        check(
          (await db.outboxDao.pendingForChat('c1'))
              .map((op) => op.kind)
              .toList(),
        ).deepEquals(['updateChat']);
      },
    );

    test(
      'cancelQueuedCompletion removes one failed assistant placeholder',
      () async {
        await seedServerChat('c1');
        await db.chatsDao.appendMessagesWithUpdateOp(
          chatId: 'c1',
          currentMessageId: 'a2',
          updatedAt: 500,
          messages: <MessageRowData>[
            MessageRowData(
              id: 'u2',
              chatId: 'c1',
              parentId: 'm1',
              role: 'user',
              content: 'next',
              createdAt: 400,
              orderIndex: 0,
              payload: const <String, dynamic>{
                'id': 'u2',
                'parentId': 'm1',
                'childrenIds': <String>['a2'],
                'role': 'user',
                'content': 'next',
                'metadata': <String, dynamic>{
                  'childrenIds': <String>['a2'],
                },
              },
            ),
            MessageRowData(
              id: 'a2',
              chatId: 'c1',
              parentId: 'u2',
              role: 'assistant',
              content: '',
              createdAt: 401,
              orderIndex: 0,
              payload: const <String, dynamic>{
                'id': 'a2',
                'parentId': 'u2',
                'childrenIds': <String>[],
                'role': 'assistant',
                'content': '',
              },
            ),
          ],
          enqueueCompletion: true,
          completion: const RequestCompletionPayload(
            assistantMessageId: 'a2',
            model: 'gpt',
          ),
        );
        final completionOp = (await db.outboxDao.pendingForChat('c1'))
            .where((op) => op.kind == OutboxKind.requestCompletion.name)
            .single;
        await db.outboxDao.markParked(completionOp.seq, error: 'boom');

        final removed = await db.chatsDao.cancelQueuedCompletion(
          'c1',
          assistantMessageId: 'a2',
        );

        check(removed).equals(1);
        final messages = await db.messagesDao.getForChat('c1');
        check(messages.map((m) => m.id).toSet()).deepEquals({'m1', 'u2'});
        check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('u2');
        check(await db.outboxDao.watchQueuedCompletionsForChat('c1').first)
            .isEmpty();
        check(
          (await db.outboxDao.pendingForChat('c1'))
              .map((op) => op.kind)
              .toList(),
        ).deepEquals(['updateChat']);
      },
    );

    test('cancelQueuedCompletion enqueues an update after a failed partial response', () async {
      await seedServerChat('c1');
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: 'c1',
        currentMessageId: 'a2',
        updatedAt: 500,
        messages: <MessageRowData>[
          MessageRowData(
            id: 'u2',
            chatId: 'c1',
            parentId: 'm1',
            role: 'user',
            content: 'next',
            createdAt: 400,
            orderIndex: 0,
            payload: const <String, dynamic>{
              'id': 'u2',
              'parentId': 'm1',
              'childrenIds': <String>['a2'],
              'role': 'user',
              'content': 'next',
              'metadata': <String, dynamic>{
                'childrenIds': <String>['a2'],
              },
            },
          ),
          MessageRowData(
            id: 'a2',
            chatId: 'c1',
            parentId: 'u2',
            role: 'assistant',
            content: '',
            createdAt: 401,
            orderIndex: 0,
            payload: const <String, dynamic>{
              'id': 'a2',
              'parentId': 'u2',
              'childrenIds': <String>[],
              'role': 'assistant',
              'content': '',
            },
          ),
        ],
        enqueueCompletion: true,
        completion: const RequestCompletionPayload(
          assistantMessageId: 'a2',
          model: 'gpt',
        ),
      );
      final initialOps = await db.outboxDao.pendingForChat('c1');
      final updateSeq = initialOps
          .where((op) => op.kind == OutboxKind.updateChat.name)
          .single
          .seq;
      final completionSeq = initialOps
          .where((op) => op.kind == OutboxKind.requestCompletion.name)
          .single
          .seq;
      await db.outboxDao.markDone(updateSeq);
      await (db.update(db.messages)..where((t) => t.id.equals('a2'))).write(
        const MessagesCompanion(
          content: Value('partial'),
          payload: Value('{"id":"a2","role":"assistant","content":"partial"}'),
        ),
      );
      await db.outboxDao.markParked(completionSeq, error: 'boom');

      final removed = await db.chatsDao.cancelQueuedCompletion(
        'c1',
        assistantMessageId: 'a2',
      );

      check(removed).equals(1);
      final messages = await db.messagesDao.getForChat('c1');
      check(messages.map((m) => m.id).toSet()).deepEquals({'m1', 'u2'});
      final chat = (await db.chatsDao.getChat('c1'))!;
      check(chat.currentMessageId).equals('u2');
      check(chat.dirty).isTrue();
      check(messages.singleWhere((m) => m.id == 'u2').dirty).isTrue();
      final blob = await rebuiltBlob('c1');
      final history = blob['history'] as Map<String, dynamic>;
      final blobMessages = history['messages'] as Map<String, dynamic>;
      check(blobMessages.containsKey('a2')).isFalse();
      final parentPayload = blobMessages['u2'] as Map<String, dynamic>;
      check(parentPayload['childrenIds'] as List<dynamic>)
          .deepEquals(<String>[]);
      final metadata = parentPayload['metadata'] as Map<String, dynamic>;
      check(metadata['childrenIds'] as List<dynamic>).deepEquals(<String>[]);
      check(
        (await db.outboxDao.pendingForChat('c1')).map((op) => op.kind).toList(),
      ).deepEquals(['updateChat']);
    });

    test('cancelQueuedCompletion enqueues an update after a pending response was pushed', () async {
      await seedServerChat('c1');
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: 'c1',
        currentMessageId: 'a2',
        updatedAt: 500,
        messages: <MessageRowData>[
          MessageRowData(
            id: 'u2',
            chatId: 'c1',
            parentId: 'm1',
            role: 'user',
            content: 'next',
            createdAt: 400,
            orderIndex: 0,
            payload: const <String, dynamic>{
              'id': 'u2',
              'parentId': 'm1',
              'childrenIds': <String>['a2'],
              'role': 'user',
              'content': 'next',
              'metadata': <String, dynamic>{
                'childrenIds': <String>['a2'],
              },
            },
          ),
          MessageRowData(
            id: 'a2',
            chatId: 'c1',
            parentId: 'u2',
            role: 'assistant',
            content: '',
            createdAt: 401,
            orderIndex: 0,
            payload: const <String, dynamic>{
              'id': 'a2',
              'parentId': 'u2',
              'childrenIds': <String>[],
              'role': 'assistant',
              'content': '',
            },
          ),
        ],
        enqueueCompletion: true,
        completion: const RequestCompletionPayload(
          assistantMessageId: 'a2',
          model: 'gpt',
        ),
      );
      final updateSeq = (await db.outboxDao.pendingForChat('c1'))
          .where((op) => op.kind == OutboxKind.updateChat.name)
          .single
          .seq;
      await db.outboxDao.markDone(updateSeq);

      final removed = await db.chatsDao.cancelQueuedCompletion(
        'c1',
        assistantMessageId: 'a2',
      );

      check(removed).equals(1);
      final messages = await db.messagesDao.getForChat('c1');
      check(messages.map((m) => m.id).toSet()).deepEquals({'m1', 'u2'});
      final chat = (await db.chatsDao.getChat('c1'))!;
      check(chat.currentMessageId).equals('u2');
      check(chat.dirty).isTrue();
      check(messages.singleWhere((m) => m.id == 'u2').dirty).isTrue();
      final blob = await rebuiltBlob('c1');
      final history = blob['history'] as Map<String, dynamic>;
      final blobMessages = history['messages'] as Map<String, dynamic>;
      check(blobMessages.containsKey('a2')).isFalse();
      final parentPayload = blobMessages['u2'] as Map<String, dynamic>;
      check(parentPayload['childrenIds'] as List<dynamic>)
          .deepEquals(<String>[]);
      final metadata = parentPayload['metadata'] as Map<String, dynamic>;
      check(metadata['childrenIds'] as List<dynamic>).deepEquals(<String>[]);
      check(
        (await db.outboxDao.pendingForChat('c1')).map((op) => op.kind).toList(),
      ).deepEquals(['updateChat']);
    });
  });

  group('R2: rollback leaves NEITHER rows nor op', () {
    test('a throw inside insertLocalChatWithCreateOp rolls back rows + op', () async {
      const localId = 'local:dup';
      final rows = newLocalRows(localId);
      // Pre-insert the chat row so the in-txn insert hits a PK conflict and
      // throws — AFTER which the op enqueue must never persist (txn rollback).
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: localId,
              title: 'pre',
              createdAt: 1,
              updatedAt: 1,
            ),
          );

      await check(
        db.chatsDao.insertLocalChatWithCreateOp(
          chat: rows.chat,
          messages: rows.messages,
          blobRows: rows,
          contentHash: 'h',
        ),
      ).throws<Object>();

      // No messages inserted, no outbox op — both rolled back.
      check(await db.messagesDao.getForChat(localId)).isEmpty();
      check(await db.outboxDao.pendingForChat(localId)).isEmpty();
      // The pre-existing stub row is untouched (title still 'pre').
      check((await db.chatsDao.getChat(localId))!.title).equals('pre');
    });
  });

  group('a comparison turn on an existing chat', () {
    const slotIds = ['a2', 'a3'];

    MessageRowData userRow() => MessageRowData(
      id: 'u2',
      chatId: 'c1',
      parentId: 'm1',
      role: 'user',
      content: 'compare',
      createdAt: 400,
      orderIndex: 0,
      payload: const <String, dynamic>{
        'id': 'u2',
        'parentId': 'm1',
        'childrenIds': <String>['a2', 'a3'],
        'role': 'user',
        'content': 'compare',
        'models': <String>['gpt', 'gpt'],
      },
    );

    MessageRowData assistantRow(String id, int slot) => MessageRowData(
      id: id,
      chatId: 'c1',
      parentId: 'u2',
      role: 'assistant',
      content: '',
      model: 'gpt',
      createdAt: 401 + slot,
      orderIndex: 0,
      payload: <String, dynamic>{
        'id': id,
        'parentId': 'u2',
        'childrenIds': const <String>[],
        'role': 'assistant',
        'content': '',
        'model': 'gpt',
        'modelIdx': slot,
      },
    );

    /// Admits the two-answer turn. [damagedComparison] then replaces the
    /// stored snapshot, as a damaged outbox row would hold it.
    Future<void> admit({
      List<String>? chatModels,
      Map<String, dynamic>? damagedComparison,
    }) async {
      final completion = RequestCompletionPayload(
        assistantMessageId: 'a2',
        model: 'gpt',
        comparison: const ComparisonGroupSnapshot(
          userMessageId: 'u2',
          slots: [
            ComparisonSlotSnapshot(
              assistantMessageId: 'a2',
              model: 'gpt',
              modelIdx: 0,
            ),
            ComparisonSlotSnapshot(
              assistantMessageId: 'a3',
              model: 'gpt',
              modelIdx: 1,
            ),
          ],
        ),
      );
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: 'c1',
        currentMessageId: 'a2',
        updatedAt: 500,
        chatModels: chatModels,
        messages: [userRow(), assistantRow('a2', 0), assistantRow('a3', 1)],
        enqueueCompletion: true,
        completion: completion,
      );
      if (damagedComparison != null) {
        final op = (await db.outboxDao.pendingForChat(
          'c1',
        )).singleWhere((op) => op.kind == OutboxKind.requestCompletion.name);
        final payload = jsonDecode(op.payload) as Map<String, dynamic>;
        payload['comparison'] = damagedComparison;
        await (db.update(db.outboxDao.outboxOps)
              ..where((t) => t.seq.equals(op.seq)))
            .write(OutboxOpsCompanion(payload: Value(jsonEncode(payload))));
      }
    }

    test(
      'cancelling it before dispatch removes every answer placeholder',
      () async {
        await seedServerChat('c1');
        await admit();

        final removed = await db.chatsDao.cancelPendingCompletion('c1');

        check(removed).equals(1);
        final messages = await db.messagesDao.getForChat('c1');
        check(messages.map((m) => m.id).toSet()).deepEquals({'m1', 'u2'});
        check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('u2');
        final blob = await rebuiltBlob('c1');
        final blobMessages =
            (blob['history'] as Map<String, dynamic>)['messages']
                as Map<String, dynamic>;
        check(blobMessages.keys.toSet()).deepEquals({'m1', 'u2'});
        check(
          (blobMessages['u2'] as Map<String, dynamic>)['childrenIds']
              as List<dynamic>,
        ).deepEquals(<String>[]);
        check(
          (await db.outboxDao.pendingForChat('c1')).map((op) => op.kind),
        ).deepEquals(['updateChat']);
      },
    );

    test(
      'cancelling a damaged snapshot still clears every readable placeholder',
      () async {
        await seedServerChat('c1');
        await admit(
          damagedComparison: <String, dynamic>{
            'userMessageId': 'u2',
            'slots': [
              for (final id in slotIds)
                <String, dynamic>{
                  'assistantMessageId': id,
                  'model': 'gpt',
                  'modelIdx': slotIds.indexOf(id),
                },
              <String, dynamic>{},
            ],
          },
        );

        await db.chatsDao.cancelPendingCompletion('c1');

        check(
          (await db.messagesDao.getForChat('c1')).map((m) => m.id).toSet(),
        ).deepEquals({'m1', 'u2'});
      },
    );

    test(
      'dismissing one answer of a queued comparison dismisses the whole turn',
      () async {
        await seedServerChat('c1');
        await admit();
        final op = (await db.outboxDao.pendingForChat(
          'c1',
        )).singleWhere((op) => op.kind == OutboxKind.requestCompletion.name);
        await db.outboxDao.markParked(op.seq, error: 'boom');

        // The sibling, not the primary, is the one the user dismisses.
        final removed = await db.chatsDao.cancelQueuedCompletion(
          'c1',
          assistantMessageId: 'a3',
        );

        check(removed).equals(1);
        check(
          (await db.messagesDao.getForChat('c1')).map((m) => m.id).toSet(),
        ).deepEquals({'m1', 'u2'});
        check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('u2');
        check(
          (await db.outboxDao.pendingForChat('c1')).map((op) => op.kind),
        ).deepEquals(['updateChat']);
      },
    );

    Future<void> seedChatWithEnvelope() async {
      final rows = ChatBlobMapper.blobToRows(
        chatId: 'c1',
        title: 'Title c1',
        createdAt: 1,
        updatedAt: 1,
        blob: <String, dynamic>{
          'title': 'Title c1',
          'models': <String>['older-model'],
          'params': <String, dynamic>{'temperature': 0.2},
          'x_upstream_only': <String, dynamic>{'keep': true},
          'history': <String, dynamic>{
            'currentId': 'm1',
            'messages': <String, dynamic>{
              'm1': <String, dynamic>{
                'id': 'm1',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': 'hello',
                'timestamp': 1,
              },
            },
          },
        },
      );
      await db.chatsDao.upsertServerChat(rows: rows);
    }

    test(
      'the chat\'s model list is written beside the rows and the one op, '
      'keeping every other envelope field',
      () async {
        await seedChatWithEnvelope();

        await admit(chatModels: const ['gpt', 'gpt']);

        final blob = await rebuiltBlob('c1');
        check(blob['models']).isA<List<Object?>>().deepEquals(['gpt', 'gpt']);
        check(blob['params']).isA<Map<String, dynamic>>().deepEquals({
          'temperature': 0.2,
        });
        check(blob['x_upstream_only']).isA<Map<String, dynamic>>().deepEquals({
          'keep': true,
        });
        final history = blob['history'] as Map<String, dynamic>;
        check(history['currentId']).equals('a2');
        final blobMessages = history['messages'] as Map<String, dynamic>;
        check(blobMessages.keys.toSet()).deepEquals({'m1', 'u2', 'a2', 'a3'});
        check(
          [
            for (final id in slotIds)
              (blobMessages[id] as Map<String, dynamic>)['modelIdx'],
          ],
        ).deepEquals([0, 1]);
        check(
          (await db.outboxDao.pendingForChat('c1')).map((op) => op.kind),
        ).deepEquals(['updateChat', 'requestCompletion']);
      },
    );

    test('an unreadable envelope rolls the whole admission back', () async {
      await seedChatWithEnvelope();
      await db.customStatement(
        "UPDATE chats SET raw_extra = '[1]' WHERE id = 'c1'",
      );

      await check(admit(chatModels: const ['gpt', 'gpt'])).throws<StateError>();

      check(
        (await db.messagesDao.getForChat('c1')).map((m) => m.id),
      ).deepEquals(['m1']);
      check(await db.outboxDao.pendingForChat('c1')).isEmpty();
      check((await db.chatsDao.getChat('c1'))!.currentMessageId).equals('m1');
    });
  });
}
