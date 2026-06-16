import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/search_dao.dart';
import 'package:conduit/core/database/fts/fts_ddl.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Inserts a chat envelope row (fires the chats AFTER INSERT FTS trigger).
Future<void> _insertChat(
  AppDatabase db, {
  required String id,
  required String title,
  int createdAt = 100,
  int updatedAt = 100,
  bool deleted = false,
}) {
  return db
      .into(db.chats)
      .insert(
        ChatsCompanion.insert(
          id: id,
          title: title,
          createdAt: createdAt,
          updatedAt: updatedAt,
          deleted: Value(deleted),
        ),
      );
}

/// Inserts a message row (fires the messages AFTER INSERT FTS trigger).
Future<void> _insertMessage(
  AppDatabase db, {
  required String id,
  required String chatId,
  required String content,
  int orderIndex = 0,
}) {
  return db
      .into(db.messages)
      .insert(
        MessagesCompanion.insert(
          id: id,
          chatId: chatId,
          role: 'user',
          content: content,
          createdAt: 100,
          orderIndex: orderIndex,
          payload: '{}',
        ),
      );
}

/// Inserts a note row (fires the notes AFTER INSERT FTS triggers).
Future<void> _insertNote(
  AppDatabase db, {
  required String id,
  required String title,
  required String body,
  int createdAt = 100,
  int updatedAt = 100,
}) {
  return db
      .into(db.notes)
      .insert(
        NotesCompanion.insert(
          id: id,
          title: title,
          data: Value(
            jsonEncode({
              'content': {'md': body},
            }),
          ),
          createdAt: createdAt,
          updatedAt: updatedAt,
        ),
      );
}

void main() {
  late bool previousDontWarnAboutMultipleDatabases;

  setUpAll(() {
    // Several tests intentionally open additional in-memory databases (separate
    // executors) to exercise the pre-FTS backfill flow; the multi-database
    // warning is expected and benign here.
    previousDontWarnAboutMultipleDatabases =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  tearDownAll(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases =
        previousDontWarnAboutMultipleDatabases;
  });

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // The vtable + triggers are normally created by buildFtsIfNeeded post-sync.
    // Create them up front so direct inserts below maintain the index.
    await db.buildFtsIfNeeded();
  });

  tearDown(() async {
    await db.close();
  });

  group('search ranking + grouping (§F)', () {
    test('returns ranked results grouped to one row per chat', () async {
      await _insertChat(db, id: 'c1', title: 'Banana bread recipe');
      await _insertChat(db, id: 'c2', title: 'Unrelated chat');
      // c2 mentions banana many times -> should rank higher (lower bm25).
      await _insertMessage(
        db,
        id: 'm1',
        chatId: 'c1',
        content: 'I made banana muffins today',
      );
      await _insertMessage(
        db,
        id: 'm2',
        chatId: 'c2',
        content: 'banana banana banana smoothie banana',
      );
      await _insertMessage(
        db,
        id: 'm3',
        chatId: 'c2',
        content: 'more banana talk',
      );

      final hits = await db.searchDao.search('banana');
      final ids = hits.map((h) => h.chatId).toList();
      // Both chats match; grouped to exactly one row each.
      check(ids.toSet()).deepEquals({'c1', 'c2'});
      check(ids.length).equals(2);
      // Ranked: lower bm25 first. c2 has far more occurrences.
      check(hits.first.chatId).equals('c2');
      // Result carries narrow envelope + snippet.
      final c2 = hits.firstWhere((h) => h.chatId == 'c2');
      check(c2.title).equals('Unrelated chat');
      check(c2.snippet).isNotNull();
    });

    test('matches chat titles, not just message content', () async {
      await _insertChat(db, id: 'c1', title: 'Quantum physics notes');
      await _insertMessage(
        db,
        id: 'm1',
        chatId: 'c1',
        content: 'something else entirely',
      );
      final hits = await db.searchDao.search('quantum');
      check(hits.map((h) => h.chatId).toList()).deepEquals(['c1']);
    });

    test('empty / punctuation query short-circuits to []', () async {
      await _insertChat(db, id: 'c1', title: 'hello world');
      check(await db.searchDao.search('')).isEmpty();
      check(await db.searchDao.search('   ')).isEmpty();
    });

    test('tombstoned chats never surface', () async {
      await _insertChat(db, id: 'c1', title: 'visible widget');
      await _insertChat(db, id: 'c2', title: 'hidden widget', deleted: true);
      await _insertMessage(db, id: 'm2', chatId: 'c2', content: 'widget talk');
      final hits = await db.searchDao.search('widget');
      check(hits.map((h) => h.chatId).toList()).deepEquals(['c1']);
    });

    test('limit + offset page results', () async {
      for (var i = 0; i < 5; i++) {
        await _insertChat(db, id: 'c$i', title: 'apple chat $i');
      }
      final firstPage = await db.searchDao.search('apple', limit: 2);
      check(firstPage.length).equals(2);
      final secondPage = await db.searchDao.search(
        'apple',
        limit: 2,
        offset: 2,
      );
      check(secondPage.length).equals(2);
      final overlap = firstPage
          .map((h) => h.chatId)
          .toSet()
          .intersection(secondPage.map((h) => h.chatId).toSet());
      check(overlap).isEmpty();
    });

    test('searchAll supports combined pagination', () async {
      for (var i = 0; i < 3; i++) {
        await _insertChat(db, id: 'c$i', title: 'papaya chat $i');
        await _insertNote(db, id: 'n$i', title: 'papaya note $i', body: 'body');
      }

      final firstPage = await db.searchDao.searchAll('papaya', limit: 2);
      final secondPage = await db.searchDao.searchAll(
        'papaya',
        limit: 2,
        offset: 2,
      );

      check(firstPage).length.equals(2);
      check(secondPage).length.equals(2);
      final firstIds = firstPage
          .map((h) => '${h.kind.name}:${h.chatId}')
          .toSet();
      final secondIds = secondPage
          .map((h) => '${h.kind.name}:${h.chatId}')
          .toSet();
      check(firstIds.intersection(secondIds)).isEmpty();
    });

    test('searchAll caps deep offsets', () async {
      await _insertChat(db, id: 'c', title: 'papaya chat');
      await _insertNote(db, id: 'n', title: 'papaya note', body: 'body');

      final hits = await db.searchDao.searchAll('papaya', offset: 1000);

      check(hits).isEmpty();
    });

    test('note search hits expose epoch-second timestamps', () async {
      await _insertNote(
        db,
        id: 'n',
        title: 'papaya note',
        body: 'body',
        createdAt: 1700000000123456789,
        updatedAt: 1700000001987654321,
      );

      final hit = (await db.searchDao.searchNotes('papaya')).single;
      check(hit.createdAt).equals(1700000000);
      check(hit.updatedAt).equals(1700000001);
    });

    test('adversarial input does not crash the query', () async {
      await _insertChat(db, id: 'c1', title: 'safe chat');
      // None of these should throw.
      for (final q in const [
        'foo AND bar',
        '"',
        '(',
        'NEAR/2',
        "'; DROP TABLE chats; --",
        '日本語',
      ]) {
        final hits = await db.searchDao.search(q);
        check(hits).isA<List<SearchHit>>();
      }
      // The table is intact after the injection attempt.
      check(await db.chatsDao.getChat('c1')).isNotNull();
    });
  });

  group('triggers keep the index correct (§C)', () {
    test('message insert is searchable; delete removes it', () async {
      await _insertChat(db, id: 'c1', title: 'plain title');
      await _insertMessage(
        db,
        id: 'm1',
        chatId: 'c1',
        content: 'ephemeral keyword here',
      );
      check(await db.searchDao.search('ephemeral')).isNotEmpty();

      await (db.delete(
        db.messages,
      )..where((t) => t.chatId.equals('c1') & t.id.equals('m1'))).go();
      check(await db.searchDao.search('ephemeral')).isEmpty();
    });

    test('message content update re-indexes', () async {
      await _insertChat(db, id: 'c1', title: 'plain title');
      await _insertMessage(
        db,
        id: 'm1',
        chatId: 'c1',
        content: 'alpha original',
      );
      check(await db.searchDao.search('original')).isNotEmpty();

      await (db.update(db.messages)
            ..where((t) => t.chatId.equals('c1') & t.id.equals('m1')))
          .write(const MessagesCompanion(content: Value('omega replaced')));

      check(await db.searchDao.search('original')).isEmpty();
      check(await db.searchDao.search('replaced')).isNotEmpty();
    });

    test('chat title update re-indexes the title row', () async {
      await _insertChat(db, id: 'c1', title: 'firstname');
      check(await db.searchDao.search('firstname')).isNotEmpty();

      await (db.update(db.chats)..where((t) => t.id.equals('c1'))).write(
        const ChatsCompanion(title: Value('secondname')),
      );

      check(await db.searchDao.search('firstname')).isEmpty();
      check(await db.searchDao.search('secondname')).isNotEmpty();
    });

    test(
      'chat hard-delete purges both title and message rows (FK-cascade safe)',
      () async {
        await _insertChat(db, id: 'c1', title: 'doomed title');
        await _insertMessage(
          db,
          id: 'm1',
          chatId: 'c1',
          content: 'doomed message body',
        );
        check(await db.searchDao.search('doomed')).isNotEmpty();

        // hardDelete FK-cascades the messages; trigger #6 purges all fts rows.
        await db.chatsDao.hardDelete('c1');

        check(await db.searchDao.search('doomed')).isEmpty();
        // Confirm directly there are zero leftover chat_fts rows for c1.
        final leftover = await db
            .customSelect(
              "SELECT count(*) AS n FROM chat_fts WHERE chat_id = 'c1'",
            )
            .getSingle();
        check(leftover.read<int>('n')).equals(0);
      },
    );

    test('chat soft-delete purges both title and message rows', () async {
      await _insertChat(db, id: 'soft-chat', title: 'softgone title');
      await _insertMessage(
        db,
        id: 'm1',
        chatId: 'soft-chat',
        content: 'softgone body',
      );
      check(await db.searchDao.search('softgone')).isNotEmpty();

      await (db.update(db.chats)..where((t) => t.id.equals('soft-chat'))).write(
        const ChatsCompanion(deleted: Value(true)),
      );

      check(await db.searchDao.search('softgone')).isEmpty();
      final leftover = await db
          .customSelect(
            "SELECT count(*) AS n FROM chat_fts WHERE chat_id = 'soft-chat'",
          )
          .getSingle();
      check(leftover.read<int>('n')).equals(0);
    });

    test('note soft-delete purges both note rows', () async {
      await _insertNote(
        db,
        id: 'soft-note',
        title: 'softnote title',
        body: 'softnote body',
      );
      check(await db.searchDao.searchNotes('softnote')).isNotEmpty();

      await (db.update(db.notes)..where((t) => t.id.equals('soft-note'))).write(
        const NotesCompanion(deleted: Value(true)),
      );

      check(await db.searchDao.searchNotes('softnote')).isEmpty();
      final leftover = await db
          .customSelect(
            "SELECT count(*) AS n FROM chat_fts WHERE chat_id = 'soft-note'",
          )
          .getSingle();
      check(leftover.read<int>('n')).equals(0);
    });

    test('note delete preserves chat FTS rows for a colliding id', () async {
      const id = 'same-uuid';
      await _insertChat(db, id: id, title: 'collision chat title');
      await _insertMessage(
        db,
        id: 'm1',
        chatId: id,
        content: 'collision chat body',
      );
      await _insertNote(
        db,
        id: id,
        title: 'collision note title',
        body: 'collision note body',
      );

      check(await db.searchDao.search('chat')).isNotEmpty();
      check(await db.searchDao.searchNotes('note')).isNotEmpty();

      await (db.delete(db.notes)..where((t) => t.id.equals(id))).go();

      check(await db.searchDao.search('chat')).isNotEmpty();
      check(await db.searchDao.searchNotes('note')).isEmpty();
    });

    test('chat delete preserves note FTS rows for a colliding id', () async {
      const id = 'same-uuid';
      await _insertChat(db, id: id, title: 'collision chat title');
      await _insertMessage(
        db,
        id: 'm1',
        chatId: id,
        content: 'collision chat body',
      );
      await _insertNote(
        db,
        id: id,
        title: 'collision note title',
        body: 'collision note body',
      );

      check(await db.searchDao.search('chat')).isNotEmpty();
      check(await db.searchDao.searchNotes('note')).isNotEmpty();

      await db.chatsDao.hardDelete(id);

      check(await db.searchDao.search('chat')).isEmpty();
      check(await db.searchDao.searchNotes('note')).isNotEmpty();
    });
  });

  group('population gate (§E)', () {
    test('buildFtsIfNeeded is idempotent (no duplicate index rows)', () async {
      // Insert BEFORE the index exists by using a fresh db with manual rows.
      final fresh = AppDatabase(NativeDatabase.memory());
      addTearDown(fresh.close);
      // No FTS yet — insert rows with triggers absent, then backfill once.
      // (Simulate the real flow: rows land during first sync, FTS built after.)
      await fresh
          .into(fresh.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'c1',
              title: 'preexisting title',
              createdAt: 1,
              updatedAt: 1,
            ),
          );
      // Triggers don't exist yet, so this row is NOT auto-indexed.
      await fresh
          .into(fresh.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'm1',
              chatId: 'c1',
              role: 'user',
              content: 'preexisting body',
              createdAt: 1,
              orderIndex: 0,
              payload: '{}',
            ),
          );

      await fresh.buildFtsIfNeeded();
      final firstCount = await _ftsRowCount(fresh);
      check(firstCount).equals(2); // one title + one message row

      // Second call is gated by the flag — no re-backfill, no duplicates.
      await fresh.buildFtsIfNeeded();
      check(await _ftsRowCount(fresh)).equals(firstCount);

      // And it is actually searchable.
      check(await fresh.searchDao.search('preexisting')).isNotEmpty();
    });

    test(
      'backfill replaces rows written by live triggers before the gate',
      () async {
        final fresh = AppDatabase(NativeDatabase.memory());
        addTearDown(fresh.close);

        await fresh.customStatement(kCreateChatFts);
        for (final trigger in kChatFtsTriggers) {
          await fresh.customStatement(trigger);
        }

        await _insertChat(fresh, id: 'c1', title: 'triggered title');
        await _insertMessage(
          fresh,
          chatId: 'c1',
          id: 'm1',
          content: 'triggered body',
        );
        check(await _ftsRowCount(fresh)).equals(2);
        check(await fresh.syncMetaDao.getValue(kFtsBuiltKey)).isNull();

        await fresh.buildFtsIfNeeded();

        check(await _ftsRowCount(fresh)).equals(2);
        check(await fresh.searchDao.search('triggered')).isNotEmpty();
      },
    );

    test('backfill excludes deleted chats and their messages', () async {
      final fresh = AppDatabase(NativeDatabase.memory());
      addTearDown(fresh.close);
      await fresh
          .into(fresh.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'c1',
              title: 'gone chat',
              createdAt: 1,
              updatedAt: 1,
              deleted: const Value(true),
            ),
          );
      await fresh
          .into(fresh.messages)
          .insert(
            MessagesCompanion.insert(
              id: 'm1',
              chatId: 'c1',
              role: 'user',
              content: 'gone message body',
              createdAt: 1,
              orderIndex: 0,
              payload: '{}',
            ),
          );
      await fresh.buildFtsIfNeeded();
      // Neither the deleted chat title nor its message content is backfilled.
      check(await fresh.searchDao.search('gone')).isEmpty();
      check(await _ftsRowCount(fresh)).equals(0);
    });
  });
}

Future<int> _ftsRowCount(AppDatabase db) async {
  final row = await db
      .customSelect('SELECT count(*) AS n FROM chat_fts')
      .getSingle();
  return row.read<int>('n');
}
