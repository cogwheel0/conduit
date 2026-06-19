import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:collection/collection.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/chats_dao.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/database/mappers/conversation_assembler.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/chat_blob_fixtures.dart';

const _deepEq = DeepCollectionEquality();

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('DB round-trip (RFC §6.1) for every golden fixture', () {
    for (final fixture in loadChatBlobFixtures()) {
      test(fixture.name, () async {
        final rows = rowsFromFixture(fixture);
        await db.chatsDao.upsertServerChat(rows: rows);

        final chatRow = await db.chatsDao.getChat(fixture.chatId);
        check(chatRow).isNotNull();
        final messageRows = await db.messagesDao.getForChat(fixture.chatId);

        final rebuilt = ChatBlobMapper.rowsToBlob(
          chatRowsFromDb(chatRow!, messageRows),
        );
        check(
          because:
              '${fixture.name}: blobToRows -> upsertServerChat -> getChat + '
              'getForChat -> chatRowsFromDb -> rowsToBlob must deep-equal the '
              'original blob.\nDescription: ${fixture.description}\n'
              'Rebuilt: ${jsonEncode(rebuilt)}',
          _deepEq.equals(rebuilt, fixture.blob),
        ).isTrue();

        // Sync-state columns of a full server upsert.
        check(chatRow.bodySynced).isTrue();
        check(chatRow.dirty).isFalse();
        check(chatRow.deleted).isFalse();
        check(
          chatRow.serverUpdatedAt,
        ).equals(fixture.envelope['updated_at'] as int);
      });
    }
  });

  test(
    're-upserting the same chat stays idempotent (no duplicate messages)',
    () async {
      final fixture = loadChatBlobFixtures().singleWhere(
        (f) => f.name == '02_linear_multi_turn',
      );
      final rows = rowsFromFixture(fixture);
      await db.chatsDao.upsertServerChat(rows: rows);
      final firstCount = (await db.messagesDao.getForChat(
        fixture.chatId,
      )).length;
      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(fixture));
      final messageRows = await db.messagesDao.getForChat(fixture.chatId);
      check(messageRows.length).equals(firstCount);
      final chatRow = await db.chatsDao.getChat(fixture.chatId);
      final rebuilt = ChatBlobMapper.rowsToBlob(
        chatRowsFromDb(chatRow!, messageRows),
      );
      check(_deepEq.equals(rebuilt, fixture.blob)).isTrue();
    },
  );

  group('watchChatList', () {
    test(
      'projection SQL selects no payload/rawExtra/blobMeta/meta columns',
      () async {
        final selects = <String>[];
        final recordingDb = AppDatabase(
          NativeDatabase.memory().interceptWith(_SelectRecorder(selects)),
        );
        addTearDown(recordingDb.close);

        await recordingDb.chatsDao.watchChatList().first;

        final chatSelects = selects
            .where(
              (sql) =>
                  sql.toLowerCase().contains('from "chats"') ||
                  sql.toLowerCase().contains('from chats'),
            )
            .toList();
        check(
          because: 'the watched list query itself must have run',
          chatSelects,
        ).isNotEmpty();
        for (final sql in chatSelects) {
          final lower = sql.toLowerCase();
          check(because: 'REQ §10.2 narrow projection, got: $sql', lower)
            ..not((s) => s.contains('payload'))
            ..not((s) => s.contains('raw_extra'))
            ..not((s) => s.contains('blob_meta'));
          check(
            because: 'meta column must not appear in the list SQL: $sql',
            RegExp(r'(?<![a-z0-9_])meta(?![a-z0-9_])').hasMatch(lower),
          ).isFalse();
        }
      },
    );

    test('writing 50 chats in one transaction emits exactly once', () async {
      final emissions = <List<ChatListEntry>>[];
      final sub = db.chatsDao.watchChatList().listen(emissions.add);
      addTearDown(sub.cancel);

      await _waitFor(() => emissions.isNotEmpty);
      final baseline = emissions.length;

      await db.transaction(() async {
        for (var i = 0; i < 50; i++) {
          await db.chatsDao.upsertEnvelopeStub(
            id: 'chat-$i',
            title: 'Chat $i',
            createdAt: 1749700000 + i,
            updatedAt: 1749700000 + i,
          );
        }
      });

      await _waitFor(() => emissions.length > baseline);
      // Allow any straggling (incorrect) emissions to surface before counting.
      await pumpEventQueue();
      check(
        because: 'REQ §10.1: one stream emission per transaction',
        emissions.length,
      ).equals(baseline + 1);
      check(emissions.last.length).equals(50);
    });

    test('orders by updatedAt DESC then id ASC and hides tombstones', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'b',
        title: 'tie-b',
        createdAt: 1,
        updatedAt: 100,
      );
      await db.chatsDao.upsertEnvelopeStub(
        id: 'a',
        title: 'tie-a',
        createdAt: 1,
        updatedAt: 100,
      );
      await db.chatsDao.upsertEnvelopeStub(
        id: 'c',
        title: 'newest',
        createdAt: 1,
        updatedAt: 200,
      );
      await db.chatsDao.upsertEnvelopeStub(
        id: 'd',
        title: 'tombstoned',
        createdAt: 1,
        updatedAt: 300,
      );
      await (db.update(db.chats)..where((t) => t.id.equals('d'))).write(
        const ChatsCompanion(deleted: Value(true)),
      );

      final entries = await db.chatsDao.watchChatList().first;
      check(entries.map((e) => e.id).toList()).deepEquals(['c', 'a', 'b']);
    });

    test('includes archived rows (split happens downstream)', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'arch',
        title: 'Archived',
        createdAt: 1,
        updatedAt: 1,
        archived: true,
      );
      final entries = await db.chatsDao.watchChatList().first;
      check(entries.single.archived).isTrue();
    });
  });

  group('watchChatMeta', () {
    test('emits the entry for one chat and null when absent', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'meta-1',
        title: 'Meta',
        createdAt: 11,
        updatedAt: 22,
        pinned: true,
        folderId: const Value('f-1'),
        lastReadAt: 33,
      );
      final entry = await db.chatsDao.watchChatMeta('meta-1').first;
      check(entry).isNotNull();
      check(entry!.id).equals('meta-1');
      check(entry.title).equals('Meta');
      check(entry.createdAt).equals(11);
      check(entry.updatedAt).equals(22);
      check(entry.pinned).isTrue();
      check(entry.archived).isFalse();
      check(entry.folderId).equals('f-1');
      check(entry.lastReadAt).equals(33);

      check(await db.chatsDao.watchChatMeta('missing').first).isNull();
    });
  });

  group('getChatsInFolder', () {
    test('returns non-deleted chats of the folder, updatedAt DESC', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'in-1',
        title: 'one',
        createdAt: 1,
        updatedAt: 10,
        folderId: const Value('f-1'),
      );
      await db.chatsDao.upsertEnvelopeStub(
        id: 'in-2',
        title: 'two',
        createdAt: 1,
        updatedAt: 20,
        folderId: const Value('f-1'),
      );
      await db.chatsDao.upsertEnvelopeStub(
        id: 'other',
        title: 'other folder',
        createdAt: 1,
        updatedAt: 30,
        folderId: const Value('f-2'),
      );
      final entries = await db.chatsDao.getChatsInFolder('f-1');
      check(entries.map((e) => e.id).toList()).deepEquals(['in-2', 'in-1']);
    });
  });

  group('lastReadAt is never lowered', () {
    test('upsertServerChat merges max(local, server)', () async {
      final fixture = loadChatBlobFixtures().first;

      await db.chatsDao.upsertServerChat(
        rows: rowsFromFixture(fixture),
        listLastReadAt: 100,
      );
      check(
        (await db.chatsDao.getChat(fixture.chatId))!.lastReadAt,
      ).equals(100);

      await db.chatsDao.upsertServerChat(
        rows: rowsFromFixture(fixture),
        listLastReadAt: 50,
      );
      check(
        (await db.chatsDao.getChat(fixture.chatId))!.lastReadAt,
      ).equals(100);

      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(fixture));
      check(
        (await db.chatsDao.getChat(fixture.chatId))!.lastReadAt,
      ).equals(100);

      await db.chatsDao.upsertServerChat(
        rows: rowsFromFixture(fixture),
        listLastReadAt: 200,
      );
      check(
        (await db.chatsDao.getChat(fixture.chatId))!.lastReadAt,
      ).equals(200);
    });

    test('upsertServerChat keeps null when both sides are null', () async {
      final fixture = loadChatBlobFixtures().first;
      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(fixture));
      check((await db.chatsDao.getChat(fixture.chatId))!.lastReadAt).isNull();
    });

    test('setLastReadAt only moves forward', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'lr',
        title: 'LR',
        createdAt: 1,
        updatedAt: 1,
      );
      await db.chatsDao.setLastReadAt('lr', 100);
      check((await db.chatsDao.getChat('lr'))!.lastReadAt).equals(100);
      await db.chatsDao.setLastReadAt('lr', 50);
      check((await db.chatsDao.getChat('lr'))!.lastReadAt).equals(100);
      await db.chatsDao.setLastReadAt('lr', 200);
      check((await db.chatsDao.getChat('lr'))!.lastReadAt).equals(200);
    });

    test('upsertEnvelopeStub merges max(...) on existing rows', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'st',
        title: 'Stub',
        createdAt: 1,
        updatedAt: 1,
        lastReadAt: 100,
      );
      await db.chatsDao.upsertEnvelopeStub(
        id: 'st',
        title: 'Stub',
        createdAt: 1,
        updatedAt: 2,
        lastReadAt: 50,
      );
      check((await db.chatsDao.getChat('st'))!.lastReadAt).equals(100);
      await db.chatsDao.upsertEnvelopeStub(
        id: 'st',
        title: 'Stub',
        createdAt: 1,
        updatedAt: 3,
        lastReadAt: 150,
      );
      check((await db.chatsDao.getChat('st'))!.lastReadAt).equals(150);
    });
  });

  group('upsertEnvelopeStub', () {
    test('inserts a stub with bodySynced=false and empty blobMeta', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'stub-1',
        title: 'Stub',
        createdAt: 10,
        updatedAt: 20,
      );
      final row = await db.chatsDao.getChat('stub-1');
      check(row).isNotNull();
      check(row!.bodySynced).isFalse();
      check(row.blobMeta).equals('{}');
      check(row.dirty).isFalse();
      check(row.deleted).isFalse();
      check(row.pinned).isFalse();
      check(row.archived).isFalse();
    });

    test(
      'never touches messages/bodySynced/blobMeta/rawExtra of a full chat',
      () async {
        final fixture = loadChatBlobFixtures().singleWhere(
          (f) => f.name == '02_linear_multi_turn',
        );
        await db.chatsDao.upsertServerChat(
          rows: rowsFromFixture(fixture),
          shareId: 'share-1',
          meta: const {
            'tags': ['x'],
          },
        );
        final before = await db.chatsDao.getChat(fixture.chatId);
        final messagesBefore = await db.messagesDao.getForChat(fixture.chatId);
        check(messagesBefore).isNotEmpty();

        await db.chatsDao.upsertEnvelopeStub(
          id: fixture.chatId,
          title: 'Renamed via list',
          createdAt: (fixture.envelope['created_at'] as int),
          updatedAt: (fixture.envelope['updated_at'] as int) + 5,
          pinned: true,
          folderId: const Value('f-9'),
        );

        final after = await db.chatsDao.getChat(fixture.chatId);
        check(after!.title).equals('Renamed via list');
        check(
          after.updatedAt,
        ).equals((fixture.envelope['updated_at'] as int) + 5);
        check(after.pinned).isTrue();
        check(after.folderId).equals('f-9');
        // Untouched:
        check(after.bodySynced).equals(before!.bodySynced);
        check(after.blobMeta).equals(before.blobMeta);
        check(after.rawExtra).equals(before.rawExtra);
        check(after.meta).equals(before.meta);
        check(after.shareId).equals(before.shareId);
        check(after.serverUpdatedAt).equals(before.serverUpdatedAt);
        final messagesAfter = await db.messagesDao.getForChat(fixture.chatId);
        check(messagesAfter.length).equals(messagesBefore.length);
      },
    );

    test('absent pinned/archived leave the existing values alone', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'flags',
        title: 'Flags',
        createdAt: 1,
        updatedAt: 1,
        pinned: true,
        archived: true,
      );
      await db.chatsDao.upsertEnvelopeStub(
        id: 'flags',
        title: 'Flags again',
        createdAt: 1,
        updatedAt: 2,
      );
      final row = await db.chatsDao.getChat('flags');
      check(row!.pinned).isTrue();
      check(row.archived).isTrue();
    });

    test('preserves a dirty local title while refreshing summary fields',
        () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'dirty-title',
        title: 'Original',
        createdAt: 1,
        updatedAt: 1,
        archived: true,
      );
      await db.chatsDao.updateEnvelopeWithOutbox(
        'dirty-title',
        title: const Value('Local rename'),
        updatedAt: const Value(10),
        enqueue: true,
      );

      await db.chatsDao.upsertEnvelopeStub(
        id: 'dirty-title',
        title: 'Server summary title',
        createdAt: 1,
        updatedAt: 2,
        archived: false,
      );

      final row = await db.chatsDao.getChat('dirty-title');
      check(row!.title).equals('Local rename');
      check(row.dirty).isTrue();
      check(row.updatedAt).equals(10);
      check(row.archived).isFalse();
    });

    test('absent folderId leaves the existing value alone on update', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'foldered',
        title: 'Foldered',
        createdAt: 1,
        updatedAt: 1,
        folderId: const Value('f-1'),
      );

      await db.chatsDao.upsertEnvelopeStub(
        id: 'foldered',
        title: 'Archived summary refresh',
        createdAt: 1,
        updatedAt: 2,
        archived: true,
      );

      final row = await db.chatsDao.getChat('foldered');
      check(row!.folderId).equals('f-1');
      check(row.archived).isTrue();
      check(row.updatedAt).equals(2);
    });

    test(
      'explicit null folderId clears the existing value on update',
      () async {
        await db.chatsDao.upsertEnvelopeStub(
          id: 'folder-clear',
          title: 'Foldered',
          createdAt: 1,
          updatedAt: 1,
          folderId: const Value('f-1'),
        );

        await db.chatsDao.upsertEnvelopeStub(
          id: 'folder-clear',
          title: 'Unfoldered summary refresh',
          createdAt: 1,
          updatedAt: 2,
          folderId: const Value(null),
        );

        final row = await db.chatsDao.getChat('folder-clear');
        check(row!.folderId).isNull();
        check(row.updatedAt).equals(2);
      },
    );
  });

  group('updateEnvelope', () {
    test('affects 0 rows when the id is absent', () async {
      final affected = await db.chatsDao.updateEnvelope(
        'nope',
        title: const Value('Title'),
      );
      check(affected).equals(0);
    });

    test('writes only the provided fields', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'env',
        title: 'Original',
        createdAt: 10,
        updatedAt: 20,
        folderId: const Value('f-1'),
      );
      final affected = await db.chatsDao.updateEnvelope(
        'env',
        title: const Value('Renamed'),
        pinned: const Value(true),
        updatedAt: const Value(30),
      );
      check(affected).equals(1);
      final row = await db.chatsDao.getChat('env');
      check(row!.title).equals('Renamed');
      check(row.pinned).isTrue();
      check(row.updatedAt).equals(30);
      check(row.folderId).equals('f-1');
      check(row.createdAt).equals(10);
    });

    test('clears folderId when explicitly set to null', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'env2',
        title: 'Original',
        createdAt: 10,
        updatedAt: 20,
        folderId: const Value('f-1'),
      );
      await db.chatsDao.updateEnvelope('env2', folderId: const Value(null));
      check((await db.chatsDao.getChat('env2'))!.folderId).isNull();
    });

    test('returns 0 with an all-absent companion', () async {
      await db.chatsDao.upsertEnvelopeStub(
        id: 'env3',
        title: 'Original',
        createdAt: 10,
        updatedAt: 20,
      );
      check(await db.chatsDao.updateEnvelope('env3')).equals(0);
    });
  });

  group('hardDelete', () {
    test('removes the chat row and cascades messages', () async {
      final fixture = loadChatBlobFixtures().singleWhere(
        (f) => f.name == '02_linear_multi_turn',
      );
      await db.chatsDao.upsertServerChat(rows: rowsFromFixture(fixture));
      check(await db.messagesDao.getForChat(fixture.chatId)).isNotEmpty();

      await db.chatsDao.hardDelete(fixture.chatId);

      check(await db.chatsDao.getChat(fixture.chatId)).isNull();
      check(
        because: 'PRAGMA foreign_keys=ON must cascade the messages delete',
        await db.messagesDao.getForChat(fixture.chatId),
      ).isEmpty();
    });
  });
}

/// Records every SELECT statement that reaches the executor.
class _SelectRecorder extends QueryInterceptor {
  _SelectRecorder(this.statements);

  final List<String> statements;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statements.add(statement);
    return executor.runSelect(statement, args);
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
