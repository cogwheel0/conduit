/// Phase 4 performance-budget acceptance (CDT-RFC-001 §10, §11).
///
/// Four budgets + the ranked-search acceptance, all on a generated 1000-chat
/// fixture written through the REAL first-sync writer. Databases are FILE-backed
/// (per `write_path_acceptance_test.dart`) so a "cold open" is a realistic open
/// of a populated file, not an in-memory page cache.
///
/// Budgets (§10):
///   1. cold start to interactive list  ≤ 400 ms from DB open (1000 chats)
///   2. append one message to a 500-msg chat  ≤ 10 ms transaction
///   3. zero jank from sync = exactly one list emission per merge transaction
///   4. FTS population does not block first render (non-blocking, idempotent)
/// plus: offline full-text search returns RANKED results grouped to chats.
///
/// Instrumentation goes through DebugLogger with numeric-only data maps so no
/// untrusted chat content is ever logged.
library;

import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/chats_dao.dart';
import 'package:conduit/core/database/mappers/conversation_assembler.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/large_fixture.dart';

/// Generous over-budget headroom guard so a wildly slow machine still fails
/// LOUDLY rather than the test hanging. The real assertions are the §10
/// budgets below; this only bounds pathological regressions.
const Duration _coldStartBudget = Duration(milliseconds: 400);
const Duration _appendBudget = Duration(milliseconds: 10);

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('conduit-fts-perf');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  File dbFile(String name) => File('${tempDir.path}/$name.sqlite');

  // -------------------------------------------------------------------------
  // BUDGET 1 — cold start to interactive list ≤ 400 ms from DB open.
  // -------------------------------------------------------------------------
  test('BUDGET 1: cold start to first watchChatList emission < 400ms '
      '(1000 chats, no FTS on the path)', () async {
    // Seed with one db, close it, then COLD-OPEN a fresh db over the file.
    final file = dbFile('cold-start');
    final seedDb = AppDatabase(NativeDatabase(file));
    await seedLargeFixture(seedDb);
    await seedDb.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    // Start the clock BEFORE subscribing; stop on the first emission.
    final sw = Stopwatch()..start();
    final first = Completer<List<ChatListEntry>>();
    final sub = db.chatsDao.watchChatList().listen((entries) {
      if (!first.isCompleted) first.complete(entries);
    });
    final entries = await first.future;
    sw.stop();
    await sub.cancel();

    final elapsed = sw.elapsed;
    DebugLogger.log(
      'cold-start-ms',
      scope: 'perf/list',
      data: {'ms': elapsed.inMilliseconds, 'rows': entries.length},
    );

    // The narrow projection delivers all 1000 (+1 big) rows.
    check(entries.length).equals(1001);
    // The list must emit BEFORE any FTS build is on the path — the fixture
    // above never built FTS, so fts_built is absent and the list still emits.
    check(elapsed).isLessThan(_coldStartBudget);
  });

  // -------------------------------------------------------------------------
  // BUDGET 1b — same cold-open via the internal first-page fast-path. Proves
  // getChatPage(limit:200) is a render-fast hydrate well under budget without
  // changing the provider's public API (LIST CONTRACT).
  // -------------------------------------------------------------------------
  test('LIST CONTRACT: getChatPage first page (200) cold-opens < 400ms and '
      'matches watchChatList ordering', () async {
    final file = dbFile('first-page');
    final seedDb = AppDatabase(NativeDatabase(file));
    await seedLargeFixture(seedDb);
    await seedDb.close();

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final sw = Stopwatch()..start();
    final page = await db.chatsDao.getChatPage(limit: 200, offset: 0);
    sw.stop();
    DebugLogger.log(
      'first-page-ms',
      scope: 'perf/list',
      data: {'ms': sw.elapsed.inMilliseconds, 'rows': page.length},
    );
    check(page.length).equals(200);
    check(sw.elapsed).isLessThan(_coldStartBudget);

    // Ordering is identical to watchChatList: updatedAt DESC, id ASC. The
    // fixture's strictly-decreasing updatedAt makes chat-0000 the newest.
    final firstFromStream = await db.chatsDao.watchChatList().first;
    check(
      page.map((e) => e.id).toList(),
    ).deepEquals(firstFromStream.take(200).map((e) => e.id).toList());

    // Pagination composes: second page continues with no gaps/overlaps.
    final page2 = await db.chatsDao.getChatPage(limit: 200, offset: 200);
    check(page2.first.id).equals(firstFromStream[200].id);
  });

  // -------------------------------------------------------------------------
  // BUDGET 2 — append one message to a 500-message chat ≤ 10 ms tx (FTS live).
  // -------------------------------------------------------------------------
  test(
    'BUDGET 2: append to 500-msg chat < 10ms with FTS triggers live',
    () async {
      final file = dbFile('append');
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // Seed + build FTS so the messages AFTER INSERT trigger is live for the
      // measured append (one INSERT into chat_fts), proving the trigger does
      // not blow the budget vs a full rebuild.
      final fixture = await seedAndBuildFts(db);

      // Warm up the prepared-statement cache + JIT for this exact tx shape so
      // the MEASURED append reflects production steady-state, not a one-time
      // cold-isolate compile. The warmup row is appended to a throwaway chat so
      // it does not perturb the big chat's measured insert.
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: fixture.chatIds.first,
        messages: [appendCandidate(fixture.chatIds.first)],
        enqueueCompletion: false,
      );

      final msg = appendCandidate(fixture.bigChatId);

      final sw = Stopwatch()..start();
      await db.chatsDao.appendMessagesWithUpdateOp(
        chatId: fixture.bigChatId,
        messages: [msg],
        enqueueCompletion: false,
      );
      sw.stop();

      DebugLogger.log(
        'append-ms',
        scope: 'perf/append',
        data: {'ms': sw.elapsed.inMilliseconds},
      );
      check(sw.elapsed).isLessThan(_appendBudget);
    },
  );

  // -------------------------------------------------------------------------
  // BUDGET 3 — one list emission per merge transaction (no per-row jank).
  // -------------------------------------------------------------------------
  test(
    'BUDGET 3: upsertServerChat emits the list stream EXACTLY ONCE per merge tx',
    () async {
      final file = dbFile('emissions-1');
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await seedAndBuildFts(
        db,
        chats: 50,
        msgsPerChat: 10,
        bigChatMessages: 50,
      );

      // Subscribe and drain the initial emission, then count only NEW ones.
      final emissions = <int>[];
      final ready = Completer<void>();
      final sub = db.chatsDao.watchChatList().listen((rows) {
        if (!ready.isCompleted) {
          ready.complete();
          return;
        }
        emissions.add(rows.length);
      });
      await ready.future;

      // One chat re-upserted = a full delete+reinsert of its messages inside
      // ONE transaction (and chat_fts trigger writes). Drift coalesces table
      // notifications to the commit; chat_fts is not a watched table, so its
      // trigger writes raise no extra notification on chats/messages.
      await _reupsert(db, 'chat-0000');

      await _waitUntil(
        () => emissions.isNotEmpty,
        timeout: const Duration(seconds: 2),
      );
      await _settleQueuedEmissions();
      await sub.cancel();

      DebugLogger.log(
        'sync-emissions',
        scope: 'perf/sync',
        data: {'emissions': emissions.length},
      );
      check(emissions.length).equals(1);
    },
  );

  test(
    'BUDGET 3: a batch of 10 chats each in its own tx emits EXACTLY 10 times',
    () async {
      final file = dbFile('emissions-10');
      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);
      await seedAndBuildFts(
        db,
        chats: 50,
        msgsPerChat: 10,
        bigChatMessages: 50,
      );

      var count = 0;
      final ready = Completer<void>();
      final sub = db.chatsDao.watchChatList().listen((_) {
        if (!ready.isCompleted) {
          ready.complete();
          return;
        }
        count++;
      });
      await ready.future;

      for (var i = 0; i < 10; i++) {
        await _reupsert(db, 'chat-${i.toString().padLeft(4, '0')}');
      }

      await _waitUntil(() => count >= 10, timeout: const Duration(seconds: 2));
      await _settleQueuedEmissions();
      await sub.cancel();

      DebugLogger.log(
        'sync-emissions',
        scope: 'perf/sync',
        data: {'emissions': count},
      );
      check(count).equals(10);
    },
  );

  // -------------------------------------------------------------------------
  // BUDGET 4 — FTS population does not block first render; build is idempotent.
  // -------------------------------------------------------------------------
  test(
    'BUDGET 4: list emits independently of FTS build; build is idempotent and '
    'search tolerates a not-yet-built index',
    () async {
      final file = dbFile('non-blocking');
      final seedDb = AppDatabase(NativeDatabase(file));
      await seedLargeFixture(seedDb, chats: 200, msgsPerChat: 10);
      await seedDb.close();

      final db = AppDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // Before any build: fts_built is absent/'0' and search short-circuits to
      // [] without relying on FTS contents.
      check(
        await db.syncMetaDao.getValue('fts_built'),
      ).anyOf([(it) => it.isNull(), (it) => it.equals('0')]);
      // search() sanitizes its raw argument internally (toFtsMatchQuery), so we
      // pass the raw sentinel word, not a pre-built MATCH expression.
      //
      // perfContract Budget 4 / §10.6: querying a not-yet-built chat_fts must
      // NOT throw or scan it — SearchDao must short-circuit
      // (e.g. fts_built != '1' → []) even though onCreate now installs the FTS
      // objects before the first backfill.
      final beforeBuild = await db.searchDao.search(kSentinel, limit: 20);
      check(
        because:
            'search before FTS build must return [] gracefully (perfContract '
            'Budget 4 / §10.6); a thrown "no such table: chat_fts" means '
            'SearchDao lacks the fts_built short-circuit guard.',
        beforeBuild,
      ).isEmpty();

      // Kick the list watch AND the build concurrently; the first list emission
      // must not depend on the build completing.
      final firstList = db.chatsDao.watchChatList().first;
      var buildCompleted = false;
      final buildFuture = db.buildFtsIfNeeded().whenComplete(() {
        buildCompleted = true;
      });
      final list = await firstList;
      check(buildCompleted).isFalse();
      // seedLargeFixture always appends kBigChatId on top of `chats`, so 200
      // seeded chats yield 201 rows (mirrors the 1000 -> 1001 cold-start case).
      check(list.length).equals(201);
      await buildFuture;

      // fts_built flips to '1'.
      check(await db.syncMetaDao.getValue('fts_built')).equals('1');

      // Second build is a no-op: search results are unchanged (no double-index)
      // and the flag stays '1'.
      final afterFirst = await db.searchDao.search(kSentinel, limit: 20);
      await db.buildFtsIfNeeded();
      check(await db.syncMetaDao.getValue('fts_built')).equals('1');
      final afterSecond = await db.searchDao.search(kSentinel, limit: 20);
      check(afterSecond.length).equals(afterFirst.length);
    },
  );

  // -------------------------------------------------------------------------
  // SEARCH CORRECTNESS (acceptance, not a budget) — ranked, grouped to chats.
  // -------------------------------------------------------------------------
  test('SEARCH: sentinel returns exactly the 3 planted chats, bm25-RANKED, '
      'grouped one row per chat with a non-empty snippet', () async {
    final file = dbFile('search');
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final fixture = await seedAndBuildFts(db);

    // NOTE: if this throws "unable to use function bm25 in the requested
    // context", the SearchDao query in lib/core/database/daos/search_dao.dart
    // (FTS-agent owned) wraps bm25(chat_fts, ?) inside a CTE — FTS5 auxiliary
    // functions (bm25/snippet) only work when the FTS table is the immediate
    // query target, not materialized through a CTE.
    final results = await db.searchDao.search(kSentinel, limit: 50);

    DebugLogger.log(
      'fts-query',
      scope: 'search',
      data: {'qlen': kSentinel.length, 'results': results.length},
    );

    final chatIds = results.map((r) => r.chatId).toList();
    // Exactly the three planted chats, grouped one row each.
    check(
      chatIds.toSet(),
    ).deepEquals(fixture.sentinelHitsByChatId.keys.toSet());
    check(chatIds.length).equals(3);

    // bm25 ranking: equal-length corpus, so most/earliest sentinel hits rank
    // first. The fixture planted 6 > 3 > 1 hits.
    check(chatIds).deepEquals(fixture.sentinelChatIdsByRank);

    // The sentinel lives only in message BODIES (the fixture keeps it out of
    // titles), so every hit is a message match with a non-empty snippet.
    for (final r in results) {
      check(r.snippet).isNotNull();
      check(r.snippet!).isNotEmpty();
    }
  });
}

/// Re-runs the real first-sync writer for [chatId] so the merge is a full
/// delete+reinsert of its messages inside ONE transaction (the Budget 3 path).
/// Reads the chat's current rows and rewrites them unchanged, which still fires
/// the message delete/insert + chat_fts triggers exactly as a real sync merge.
Future<void> _reupsert(AppDatabase db, String chatId) async {
  final chat = await db.chatsDao.getChat(chatId);
  if (chat == null) {
    throw StateError('missing $chatId');
  }
  final messages = await db.messagesDao.getForChat(chatId);
  // Rebuild ChatRows from the stored rows so upsertServerChat exercises the
  // real delete+reinsert of every message (and the chat_fts trigger) in one
  // transaction — the production sync-merge shape.
  await db.chatsDao.upsertServerChat(rows: chatRowsFromDb(chat, messages));
}

Future<void> _waitUntil(
  bool Function() condition, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settleQueuedEmissions() {
  return Future<void>.delayed(const Duration(milliseconds: 25));
}
