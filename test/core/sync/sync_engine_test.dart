import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

void main() {
  late FakeOpenWebUiServer server;
  late FakeSyncApiClient client;
  late AppDatabase db;
  late int purgeCalls;

  setUp(() {
    server = FakeOpenWebUiServer();
    client = FakeSyncApiClient(server);
    db = AppDatabase(NativeDatabase.memory());
    purgeCalls = 0;
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer({bool authenticated = true}) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        syncApiClientProvider.overrideWith((ref) => client),
        isAuthenticatedProvider2.overrideWith((ref) => authenticated),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {
            purgeCalls++;
          },
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('waitFor timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void seedChat(String id, int updatedAt) {
    server.seedChat(
      id: id,
      blob: {
        'title': 'Title $id',
        'history': {
          'messages': {
            '$id-m1': {
              'id': '$id-m1',
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'hello',
              'timestamp': updatedAt,
            },
          },
          'currentId': '$id-m1',
        },
      },
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );
  }

  group('SyncEngine.requestPull', () {
    test('debounce collapses a request storm into one cycle', () async {
      seedChat('chat-1', 100);
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      final futures = [
        for (var i = 0; i < 5; i++) engine.requestPull(reason: 'storm-$i'),
      ];
      final results = await Future.wait(futures);

      // Exactly one cycle ran: one main-list page, one archived page.
      check(client.chatListPageRequests).equals(1);
      check(client.archivedListPageRequests).equals(1);
      for (final result in results) {
        check(result).isNotNull();
        check(identical(result, results.first)).isTrue();
        check(result!.success).isTrue();
      }
      check(
        container.read(syncEngineProvider).lastSuccessUpdatedAtWatermark,
      ).equals(100);
      check(container.read(syncEngineProvider).phase).equals(SyncPhase.idle);
    });

    test('requests during a running cycle coalesce into one queued rerun',
        () async {
      seedChat('chat-1', 100);
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      final gate = Completer<void>();
      client.chatFetchGate = gate.future;

      final first = engine.requestPull(reason: 'initial');
      // Wait until the first cycle is provably mid-flight (blocked on the
      // gate inside its chat fetch).
      await waitFor(() => client.chatFetchStarts.isNotEmpty);

      final queued = [
        for (var i = 0; i < 3; i++) engine.requestPull(reason: 'during-$i'),
      ];
      gate.complete();

      final firstResult = await first;
      final queuedResults = await Future.wait(queued);

      check(firstResult).isNotNull();
      check(firstResult!.success).isTrue();
      for (final result in queuedResults) {
        check(result).isNotNull();
        // All three joined the SAME queued cycle.
        check(identical(result, queuedResults.first)).isTrue();
      }
      // The storm produced exactly two cycles in total.
      check(client.chatListPageRequests).equals(2);
    });

    test('inert when unauthenticated: returns null without touching the API',
        () async {
      seedChat('chat-1', 100);
      final container = makeContainer(authenticated: false);
      final engine = container.read(syncEngineProvider.notifier);

      final result = await engine.requestPull(reason: 'inert-check');

      check(result).isNull();
      check(client.chatListPageRequests).equals(0);
      check(container.read(syncEngineProvider).phase).equals(SyncPhase.idle);
    });

    test('section 9.3 legacy-cache purge fires exactly once', () async {
      seedChat('chat-1', 100);
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      final first = await engine.requestPull(reason: 'first-full-pull');
      check(first!.success).isTrue();
      check(purgeCalls).equals(1);
      check(await db.syncMetaDao.getValue('hive_cache_purged')).equals('1');

      seedChat('chat-2', 200);
      final second = await engine.requestPull(reason: 'incremental');
      check(second!.success).isTrue();
      check(purgeCalls).equals(1);
    });

    test('purge is withheld while the first full pull keeps failing',
        () async {
      seedChat('chat-1', 100);
      client.failChatIds.add('chat-1');
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      final failed = await engine.requestPull(reason: 'failing-pull');
      check(failed!.success).isFalse();
      check(purgeCalls).equals(0);
      check(await db.syncMetaDao.getValue('hive_cache_purged')).isNull();

      client.failChatIds.clear();
      final healed = await engine.requestPull(reason: 'healing-pull');
      check(healed!.success).isTrue();
      check(purgeCalls).equals(1);
    });

    test('folders 403 result flips foldersFeatureEnabledProvider', () async {
      seedChat('chat-1', 100);
      client.foldersFeatureEnabled = false;
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      check(container.read(foldersFeatureEnabledProvider)).isTrue();
      final result = await engine.requestPull(reason: 'folders-disabled');

      check(result!.foldersFeatureEnabled).equals(false);
      check(container.read(foldersFeatureEnabledProvider)).isFalse();
    });
  });

  group('SyncEngine.pullChatNow', () {
    test('is immediate (no debounce) and returns the conversation', () async {
      seedChat('chat-1', 100);
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      final stopwatch = Stopwatch()..start();
      final conversation = await engine.pullChatNow('chat-1');
      stopwatch.stop();

      check(conversation).isNotNull();
      check(conversation!.id).equals('chat-1');
      // Well under the 300 ms debounce window.
      check(stopwatch.elapsed).isLessThan(kSyncPullDebounce);
      check((await db.chatsDao.getChat('chat-1'))!.bodySynced).isTrue();
    });

    test('inert when unauthenticated', () async {
      seedChat('chat-1', 100);
      final container = makeContainer(authenticated: false);
      final engine = container.read(syncEngineProvider.notifier);

      check(await engine.pullChatNow('chat-1')).isNull();
      check(client.chatFetchStarts).isEmpty();
    });
  });
}
