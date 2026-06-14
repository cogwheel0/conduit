import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/fts/fts_ddl.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/persistence/persistence_providers.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_open_webui_server.dart';
import '../../support/fake_sync_api_client.dart';

class _FailableFtsDatabase extends AppDatabase {
  _FailableFtsDatabase(super.e);

  int buildAttempts = 0;
  final firstFailureObserved = Completer<void>();
  final retrySucceeded = Completer<void>();

  @override
  Future<void> buildFtsIfNeeded() async {
    buildAttempts++;
    if (buildAttempts == 1) {
      firstFailureObserved.complete();
      throw StateError('injected fts build failure');
    }
    await super.buildFtsIfNeeded();
    if (!retrySucceeded.isCompleted) {
      retrySucceeded.complete();
    }
  }
}

class _MutableValue<T> extends Notifier<T> {
  _MutableValue(this.initial);

  final T initial;

  @override
  T build() => initial;

  void set(T value) => state = value;
}

class _FailFinalPullWatermarkRead extends QueryInterceptor {
  int pullWatermarkReads = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (args.contains('pull_watermark')) {
      pullWatermarkReads++;
      if (pullWatermarkReads == 3) {
        throw StateError('injected pull watermark read failure');
      }
    }
    return executor.runSelect(statement, args);
  }
}

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

  ProviderContainer makeContainer({
    bool authenticated = true,
    bool online = true,
    void Function()? onHiveBoxesRead,
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        syncApiClientProvider.overrideWith((ref) => client),
        isAuthenticatedProvider2.overrideWith((ref) => authenticated),
        isOnlineProvider.overrideWith((ref) => online),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {
            purgeCalls++;
          },
        ),
        if (onHiveBoxesRead != null)
          hiveBoxesProvider.overrideWith((ref) {
            onHiveBoxesRead();
            throw StateError('transient hive read');
          }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Inserts a `local:` chat row + its createChat outbox op in one tx, exactly
  /// as the production durable-send path does, so the drainer reconstructs the
  /// blob from rows and POSTs it via [PushSync.pushCreateChat].
  Future<void> seedLocalCreate(
    String localId, {
    required String contentHash,
    AppDatabase? targetDb,
  }) {
    final target = targetDb ?? db;
    final rows = ChatBlobMapper.blobToRows(
      chatId: localId,
      title: 'Draft $localId',
      createdAt: 1,
      updatedAt: 1,
      blob: <String, dynamic>{
        'title': 'Draft $localId',
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
    return target.chatsDao.insertLocalChatWithCreateOp(
      chat: rows.chat,
      messages: rows.messages,
      blobRows: rows,
      contentHash: contentHash,
    );
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

  Future<void> waitForAsync(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!await condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('waitForAsync timed out');
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

    test(
      'requests during a running cycle coalesce into one queued rerun',
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
      },
    );

    test(
      'inert when unauthenticated: returns null without touching the API',
      () async {
        seedChat('chat-1', 100);
        final container = makeContainer(authenticated: false);
        final engine = container.read(syncEngineProvider.notifier);

        final result = await engine.requestPull(reason: 'inert-check');

        check(result).isNull();
        check(client.chatListPageRequests).equals(0);
        check(container.read(syncEngineProvider).phase).equals(SyncPhase.idle);
      },
    );

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

    test('purge is withheld while the first full pull keeps failing', () async {
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

    test('FTS build retries when the watermark already advanced', () async {
      await db.syncMetaDao.setPullWatermark(50);
      seedChat('chat-1', 100);
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      final result = await engine.requestPull(reason: 'fts-retry');
      check(result!.success).isTrue();

      await waitForAsync(
        () async => await db.syncMetaDao.getValue(kFtsBuiltKey) == '1',
      );
      check(await db.searchDao.search('hello')).isNotEmpty();
    });

    test('FTS build retries after a post-full-pull failure', () async {
      await db.close();
      final failableDb = _FailableFtsDatabase(NativeDatabase.memory());
      db = failableDb;

      seedChat('chat-1', 100);
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      final first = await engine.requestPull(reason: 'fts-build-fails');
      check(first!.success).isTrue();
      await failableDb.firstFailureObserved.future;
      await Future<void>.delayed(Duration.zero);
      check(failableDb.buildAttempts).equals(1);
      check(await db.syncMetaDao.getValue(kFtsBuiltKey)).isNull();

      seedChat('chat-2', 200);
      final second = await engine.requestPull(reason: 'fts-build-retries');
      check(second!.success).isTrue();
      await failableDb.retrySucceeded.future;

      check(failableDb.buildAttempts).equals(2);
      check(await db.syncMetaDao.getValue(kFtsBuiltKey)).equals('1');
    });

    test('watermark state read failure still completes pull joiners', () async {
      await db.close();
      final interceptor = _FailFinalPullWatermarkRead();
      db = AppDatabase(NativeDatabase.memory().interceptWith(interceptor));

      seedChat('chat-1', 100);
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      final result = await engine
          .requestPull(reason: 'watermark-finalize-failure')
          .timeout(const Duration(seconds: 2));

      check(result).isNotNull();
      check(result!.success).isTrue();
      check(interceptor.pullWatermarkReads).equals(3);
      check(container.read(syncEngineProvider).phase).equals(SyncPhase.idle);
      check(
        container.read(syncEngineProvider).lastSuccessUpdatedAtWatermark,
      ).isNull();
      check(await db.syncMetaDao.getPullWatermark()).equals(100);
    });

    test('task queue migration failure retries on the next cycle', () async {
      seedChat('chat-1', 100);
      var migrationBuildAttempts = 0;
      final container = makeContainer(
        onHiveBoxesRead: () => migrationBuildAttempts++,
      );
      final engine = container.read(syncEngineProvider.notifier);

      final first = await engine.requestPull(reason: 'migration-fails-once');
      check(first!.success).isTrue();
      container.invalidate(hiveBoxesProvider);

      seedChat('chat-2', 200);
      final second = await engine.requestPull(reason: 'migration-retries');
      check(second!.success).isTrue();

      check(migrationBuildAttempts).equals(2);
    });

    test('direct drain entry points run task queue migration first', () async {
      var migrationBuildAttempts = 0;
      final container = makeContainer(
        onHiveBoxesRead: () => migrationBuildAttempts++,
      );
      final engine = container.read(syncEngineProvider.notifier);

      await seedLocalCreate('local:drain-now', contentHash: 'h-drain-now');
      await engine.drainNow();
      check(migrationBuildAttempts).equals(1);
      check(client.createChatCalls).equals(1);
      container.invalidate(hiveBoxesProvider);

      await seedLocalCreate(
        'local:drain-outbox',
        contentHash: 'h-drain-outbox',
      );
      await engine.drainOutbox();
      check(migrationBuildAttempts).equals(2);
      check(client.createChatCalls).equals(2);
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

    test(
      'cached remapper and drainer rebind when the active database changes',
      () async {
        final firstDb = db;
        final secondDb = AppDatabase(NativeDatabase.memory());
        final activeDbProvider =
            NotifierProvider<_MutableValue<AppDatabase?>, AppDatabase?>(
              () => _MutableValue<AppDatabase?>(firstDb),
            );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith(
              (ref) => ref.watch(activeDbProvider),
            ),
            syncApiClientProvider.overrideWith((ref) => client),
            isAuthenticatedProvider2.overrideWith((ref) => true),
            isOnlineProvider.overrideWith((ref) => true),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await secondDb.close();
        });

        final engine = container.read(syncEngineProvider.notifier);
        final firstRemapper = engine.remapperForTesting;
        check(firstRemapper).isNotNull();
        await engine.drainNow(); // caches a drainer against firstDb.

        await seedLocalCreate(
          'local:after-switch',
          contentHash: 'h-after-switch',
          targetDb: secondDb,
        );
        container.read(activeDbProvider.notifier).set(secondDb);
        container.read(syncEngineProvider);

        final secondRemapper = engine.remapperForTesting;
        check(secondRemapper).isNotNull();
        check(identical(firstRemapper, secondRemapper)).isFalse();

        await engine.drainNow();

        check(client.createChatCalls).equals(1);
        check(
          await secondDb.outboxDao.pendingForChat('local:after-switch'),
        ).isEmpty();
      },
    );

    test(
      'in-flight cycle aborts before draining a newly selected database',
      () async {
        final firstDb = db;
        final secondDb = AppDatabase(NativeDatabase.memory());
        final activeDbProvider =
            NotifierProvider<_MutableValue<AppDatabase?>, AppDatabase?>(
              () => _MutableValue<AppDatabase?>(firstDb),
            );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith(
              (ref) => ref.watch(activeDbProvider),
            ),
            syncApiClientProvider.overrideWith((ref) => client),
            isAuthenticatedProvider2.overrideWith((ref) => true),
            isOnlineProvider.overrideWith((ref) => true),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await secondDb.close();
        });

        seedChat('chat-before-switch', 100);
        final engine = container.read(syncEngineProvider.notifier);
        final gate = Completer<void>();
        client.chatFetchGate = gate.future;

        final first = engine.requestPull(reason: 'switch-mid-cycle');
        await waitFor(() => client.chatFetchStarts.isNotEmpty);

        await seedLocalCreate(
          'local:after-mid-cycle-switch',
          contentHash: 'h-mid-switch',
          targetDb: secondDb,
        );
        container.read(activeDbProvider.notifier).set(secondDb);
        container.read(syncEngineProvider);

        gate.complete();
        final result = await first;

        check(result).isNull();
        check(client.createChatCalls).equals(0);
        check(
          await secondDb.outboxDao.pendingForChat(
            'local:after-mid-cycle-switch',
          ),
        ).isNotEmpty();

        await engine.drainNow();

        check(client.createChatCalls).equals(1);
        check(
          await secondDb.outboxDao.pendingForChat(
            'local:after-mid-cycle-switch',
          ),
        ).isEmpty();
      },
    );
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

  group('outbox drain serialization (one shared drainer)', () {
    test('a pull-cycle drain and a concurrent drainNow() execute a createChat '
        'exactly once (no resetInFlightToPending double-send)', () async {
      // A local createChat op is enqueued, exactly as a durable send would.
      await seedLocalCreate('local:c1', contentHash: 'h1');
      final container = makeContainer();
      final engine = container.read(syncEngineProvider.notifier);

      // Hold the FIRST createChat POST open so the op is genuinely `inFlight`
      // (claimed + mid-push) when the second drain trigger fires. If two
      // OutboxDrainer instances existed, the second's resetInFlightToPending
      // would re-arm this op and re-POST it.
      final gate = Completer<void>();
      client.createChatGate = gate.future;

      // Entry point (1): the pull cycle's post-pull drain.
      final pullDrain = engine.requestPull(reason: 'pull-cycle');
      // Wait until the createChat POST is provably in flight.
      await waitFor(() => client.createChatStarts.isNotEmpty);
      check(client.createChatCalls).equals(1);

      // Entry point (2): a live send's immediate drain (durableSend ->
      // drainNow -> onConnectivityRegained -> resetInFlightToPending +
      // drain). With one shared drainer this collapses into the in-flight
      // drain instead of resetting the in-flight op.
      final connectivityDrain = engine.drainNow();

      // Release the held POST; let everything settle.
      gate.complete();
      await pullDrain;
      await connectivityDrain;
      // Drain again to flush any queued rerun the shared single-flight
      // scheduled, proving it does NOT re-POST.
      await engine.drainNow();

      // The createChat reached the server exactly once.
      check(client.createChatCalls).equals(1);
      // The op was consumed (remapped + marked done), nothing left pending.
      check(await db.outboxDao.pendingForChat('local:c1')).isEmpty();
    });
  });
}
