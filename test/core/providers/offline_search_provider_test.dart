/// Offline full-text search reachability tests (CDT-RFC-001 Phase 4).
///
/// Proves the in-app search entry point (`serverSearchProvider`) serves ranked
/// results from the local FTS5 index when there is no server connection
/// (`apiServiceProvider == null`), and returns `[]` gracefully before the index
/// is built. The online server path and its provider API are unchanged; this
/// only exercises the offline branch wired in `app_providers.dart`.
library;

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        // No server connection -> the offline FTS branch is taken.
        apiServiceProvider.overrideWithValue(null),
        isAuthenticatedProvider2.overrideWithValue(true),
        reviewerModeProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> seedChat(
    String id, {
    required int updatedAt,
    required String content,
    String? title,
  }) {
    return db.chatsDao.upsertServerChat(
      rows: ChatBlobMapper.blobToRows(
        chatId: id,
        blob: {
          'title': title ?? 'Title $id',
          'history': {
            'messages': {
              '$id-m1': {
                'id': '$id-m1',
                'parentId': null,
                'childrenIds': <String>[],
                'role': 'user',
                'content': content,
                'timestamp': updatedAt,
              },
            },
            'currentId': '$id-m1',
          },
        },
        title: title ?? 'Title $id',
        createdAt: updatedAt,
        updatedAt: updatedAt,
      ),
    );
  }

  List<String> idsOf(List<Conversation> list) =>
      list.map((c) => c.id).toList();

  test('empty query short-circuits to [] without touching the DB', () async {
    final container = makeContainer();
    final results = await container.read(serverSearchProvider('   ').future);
    check(results).isEmpty();
  });

  test('before FTS is built, offline search returns [] gracefully', () async {
    await seedChat('chat-a', updatedAt: 1000, content: 'platypus migration');
    // Note: buildFtsIfNeeded NOT called -> fts_built flag is unset.
    final container = makeContainer();
    final results = await container.read(
      serverSearchProvider('platypus').future,
    );
    check(results).isEmpty();
  });

  test(
    'offline search returns ranked results across synced history once built',
    () async {
      // Three chats contain the sentinel at decreasing relevance via repetition.
      await seedChat(
        'chat-most',
        updatedAt: 1000,
        content: 'platypus platypus platypus river',
      );
      await seedChat(
        'chat-mid',
        updatedAt: 1001,
        content: 'platypus platypus delta',
      );
      await seedChat('chat-one', updatedAt: 1002, content: 'platypus marsh');
      await seedChat('chat-none', updatedAt: 1003, content: 'unrelated text');
      await db.buildFtsIfNeeded();

      final container = makeContainer();
      final results = await container.read(
        serverSearchProvider('platypus').future,
      );

      // Only the three sentinel-bearing chats, grouped one row each.
      check(idsOf(results).toSet()).deepEquals({
        'chat-most',
        'chat-mid',
        'chat-one',
      });
      // bm25-ranked: most repetitions first.
      check(idsOf(results)).deepEquals(['chat-most', 'chat-mid', 'chat-one']);
    },
  );

  test('offline search matches chat titles, not just message bodies', () async {
    await seedChat(
      'chat-titled',
      updatedAt: 2000,
      content: 'ordinary body text',
      title: 'Quarterly platypus report',
    );
    await db.buildFtsIfNeeded();

    final container = makeContainer();
    final results = await container.read(
      serverSearchProvider('platypus').future,
    );
    check(idsOf(results)).deepEquals(['chat-titled']);
  });

  test('adversarial FTS operator input never throws, returns []', () async {
    await seedChat('chat-x', updatedAt: 3000, content: 'safe content');
    await db.buildFtsIfNeeded();

    final container = makeContainer();
    // Bare FTS operators / unbalanced quotes would raise if not sanitized.
    final results = await container.read(
      serverSearchProvider('AND OR "(*^ NEAR').future,
    );
    check(results).isEmpty();
  });
}
