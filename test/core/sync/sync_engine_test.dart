import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/daos/outbox_dao.dart';
import 'package:conduit/core/database/database_provider.dart';
import 'package:conduit/core/database/fts/fts_ddl.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/persistence_providers.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/connectivity_service.dart';
import 'package:conduit/core/sync/clock.dart';
import 'package:conduit/core/sync/id_remapper.dart';
import 'package:conduit/core/sync/outbox_drainer.dart';
import 'package:conduit/core/sync/outbox_task_queue_migrator.dart';
import 'package:conduit/core/sync/request_completion_runner_provider.dart';
import 'package:conduit/core/sync/sync_api_client.dart';
import 'package:conduit/core/sync/sync_engine.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:mocktail/mocktail.dart';

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

class _FixedClock implements SyncClock {
  const _FixedClock(this.now);

  final int now;

  @override
  int nowEpochSeconds() => now;
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

class _GateTaskMigrationFlagRead extends QueryInterceptor {
  int taskMigrationFlagReads = 0;
  final firstReadStarted = Completer<void>();
  final releaseFirstRead = Completer<void>();

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (args.contains(OutboxTaskQueueMigrator.migratedFlagKey)) {
      taskMigrationFlagReads++;
      if (taskMigrationFlagReads == 1) {
        firstReadStarted.complete();
        await releaseFirstRead.future;
      }
    }
    return executor.runSelect(statement, args);
  }
}

class _GateFirstOutboxClaim extends QueryInterceptor {
  final claimStarted = Completer<void>();
  final releaseClaim = Completer<void>();
  bool _gated = false;

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final isClaim =
        !_gated &&
        statement.contains('outbox_ops') &&
        args.contains(OutboxStatus.inFlight);
    if (isClaim) {
      _gated = true;
      claimStarted.complete();
      await releaseClaim.future;
    }
    return executor.runUpdate(statement, args);
  }
}

class _RecordingCompletionRunner implements RequestCompletionRunner {
  final calls = <String>[];

  @override
  Future<void> run({
    required String chatId,
    required Map<String, dynamic> payload,
  }) async {
    calls.add(chatId);
  }
}

class _MockHiveBox extends Mock implements Box<dynamic> {}

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}

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
    bool Function(Ref ref)? authBuilder,
    SyncClock Function(Ref ref)? clockBuilder,
    RequestCompletionRunner? completionRunner,
    HiveBoxes? hiveBoxes,
    OptimizedStorageService? storageService,
    void Function()? onHiveBoxesRead,
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        syncApiClientProvider.overrideWith((ref) => client),
        isAuthenticatedProvider2.overrideWith(
          (ref) => authBuilder?.call(ref) ?? authenticated,
        ),
        if (clockBuilder != null) syncClockProvider.overrideWith(clockBuilder),
        if (completionRunner != null)
          requestCompletionRunnerProvider.overrideWith(
            (ref) => completionRunner,
          ),
        if (storageService != null)
          optimizedStorageServiceProvider.overrideWithValue(storageService),
        isOnlineProvider.overrideWith((ref) => online),
        legacyConversationCachePurgerProvider.overrideWith(
          (ref) => () async {
            purgeCalls++;
          },
        ),
        if (hiveBoxes != null || onHiveBoxesRead != null)
          hiveBoxesProvider.overrideWith((ref) {
            onHiveBoxesRead?.call();
            if (hiveBoxes != null) {
              return hiveBoxes;
            }
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
    RequestCompletionPayload? completion,
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
      completion: completion,
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

  _MockHiveBox emptyHiveBox() {
    final box = _MockHiveBox();
    when(() => box.containsKey(any<dynamic>())).thenReturn(false);
    when(() => box.get(any<dynamic>())).thenReturn(null);
    when(() => box.delete(any<dynamic>())).thenAnswer((_) async {});
    return box;
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

    test(
      'requestPull observes login and survives rebuild after being armed',
      () async {
        seedChat('chat-after-login', 100);
        final authProvider = NotifierProvider<_MutableValue<bool>, bool>(
          () => _MutableValue<bool>(false),
        );
        final container = makeContainer(
          authBuilder: (ref) => ref.watch(authProvider),
        );

        final engine = container.read(syncEngineProvider.notifier);
        check(await engine.requestPull(reason: 'before-login')).isNull();
        check(client.chatListPageRequests).equals(0);

        container.read(authProvider.notifier).set(true);

        final resultFuture = engine.requestPull(reason: 'after-login');
        // Force the reactive build after requestPull has armed its debounce.
        // The same joined pull must still complete, not get reset to null.
        container.read(syncEngineProvider);
        final result = await resultFuture;

        check(result).isNotNull();
        check(result!.success).isTrue();
        check(client.chatListPageRequests).equals(1);
        check(await db.chatsDao.getChat('chat-after-login')).isNotNull();
      },
    );

    test('armed requestPull survives a non-inert dependency rebind', () async {
      seedChat('chat-after-rebind', 100);
      final clockProvider =
          NotifierProvider<_MutableValue<SyncClock>, SyncClock>(
            () => _MutableValue<SyncClock>(const _FixedClock(1)),
          );
      final container = makeContainer(
        clockBuilder: (ref) => ref.watch(clockProvider),
      );
      final engine = container.read(syncEngineProvider.notifier);

      final resultFuture = engine.requestPull(reason: 'before-clock-rebind');
      container.read(clockProvider.notifier).set(const _FixedClock(2));
      // Force the reactive rebuild while the debounce joinable is still armed.
      // The waiter must be carried into the post-rebind cycle, not completed
      // early with null.
      container.read(syncEngineProvider);
      final result = await resultFuture;

      check(result).isNotNull();
      check(result!.success).isTrue();
      check(client.chatListPageRequests).equals(1);
      check(await db.chatsDao.getChat('chat-after-rebind')).isNotNull();
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

    test(
      'first chat pull does not advance note reconcile gate when notes fail',
      () async {
        seedChat('chat-1', 100);
        client.failNoteList = true;
        final container = makeContainer();
        final engine = container.read(syncEngineProvider.notifier);

        final result = await engine.requestPull(reason: 'note-pull-fails');

        check(result).isNotNull();
        check(result!.success).isTrue();
        check(await db.syncMetaDao.getLastFullReconcileAt()).isGreaterThan(0);
        check(await db.syncMetaDao.getNotesLastFullReconcileAt()).equals(0);
      },
    );

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

    test(
      'same-db dependency rebind preserves task queue migration single-flight',
      () async {
        await db.close();
        final migrationGate = _GateTaskMigrationFlagRead();
        db = AppDatabase(NativeDatabase.memory().interceptWith(migrationGate));
        final boxes = HiveBoxes(
          preferences: emptyHiveBox(),
          caches: emptyHiveBox(),
          attachmentQueue: emptyHiveBox(),
          metadata: emptyHiveBox(),
        );
        final storage = _MockOptimizedStorageService();
        when(
          () => storage.getActiveServerId(),
        ).thenAnswer((_) async => 'server-1');
        final clockProvider =
            NotifierProvider<_MutableValue<SyncClock>, SyncClock>(
              () => _MutableValue<SyncClock>(const _FixedClock(1)),
            );
        final container = makeContainer(
          clockBuilder: (ref) => ref.watch(clockProvider),
          hiveBoxes: boxes,
          storageService: storage,
        );
        final engine = container.read(syncEngineProvider.notifier);

        final firstDrain = engine.drainOutbox();
        await migrationGate.firstReadStarted.future;

        container.read(clockProvider.notifier).set(const _FixedClock(2));
        container.read(syncEngineProvider);
        final secondDrain = engine.drainNow();
        await Future<void>.delayed(Duration.zero);

        check(migrationGate.taskMigrationFlagReads).equals(1);

        migrationGate.releaseFirstRead.complete();
        await firstDrain;
        await secondDrain;

        check(migrationGate.taskMigrationFlagReads).equals(1);
      },
    );

    test(
      'same-db migration joiner retries after active migration failure',
      () async {
        await db.close();
        final migrationGate = _GateTaskMigrationFlagRead();
        db = AppDatabase(NativeDatabase.memory().interceptWith(migrationGate));
        final caches = _MockHiveBox();
        var taskQueueProbes = 0;
        when(() => caches.containsKey(HiveStoreKeys.taskQueue)).thenAnswer((_) {
          taskQueueProbes++;
          if (taskQueueProbes == 1) {
            throw StateError('transient task queue probe');
          }
          return false;
        });
        when(() => caches.get(any<dynamic>())).thenReturn(null);
        when(() => caches.delete(any<dynamic>())).thenAnswer((_) async {});
        final boxes = HiveBoxes(
          preferences: emptyHiveBox(),
          caches: caches,
          attachmentQueue: emptyHiveBox(),
          metadata: emptyHiveBox(),
        );
        final storage = _MockOptimizedStorageService();
        when(() => storage.getActiveServerId()).thenAnswer((_) async => null);
        final container = makeContainer(
          hiveBoxes: boxes,
          storageService: storage,
        );
        final engine = container.read(syncEngineProvider.notifier);

        final firstDrain = engine.drainOutbox();
        await migrationGate.firstReadStarted.future;
        final joinObserved = Completer<void>();
        engine.legacyMigrationJoinObserverForTesting = () {
          if (!joinObserved.isCompleted) {
            joinObserved.complete();
          }
        };
        final joinedDrain = engine.drainNow();
        await joinObserved.future;

        migrationGate.releaseFirstRead.complete();
        await firstDrain;
        await joinedDrain;

        check(taskQueueProbes).equals(2);
        check(
          await db.syncMetaDao.getValue(
            OutboxTaskQueueMigrator.migratedFlagKey,
          ),
        ).equals('1');
      },
    );

    test(
      'database switch waits for active task queue migration before retrying',
      () async {
        await db.close();
        final firstMigrationGate = _GateTaskMigrationFlagRead();
        final secondMigrationGate = _GateTaskMigrationFlagRead();
        final firstDb = AppDatabase(
          NativeDatabase.memory().interceptWith(firstMigrationGate),
        );
        db = firstDb;
        final secondDb = AppDatabase(
          NativeDatabase.memory().interceptWith(secondMigrationGate),
        );
        final activeDbProvider =
            NotifierProvider<_MutableValue<AppDatabase?>, AppDatabase?>(
              () => _MutableValue<AppDatabase?>(firstDb),
            );
        final boxes = HiveBoxes(
          preferences: emptyHiveBox(),
          caches: emptyHiveBox(),
          attachmentQueue: emptyHiveBox(),
          metadata: emptyHiveBox(),
        );
        final storage = _MockOptimizedStorageService();
        when(
          () => storage.getActiveServerId(),
        ).thenAnswer((_) async => 'server-1');
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith(
              (ref) => ref.watch(activeDbProvider),
            ),
            syncApiClientProvider.overrideWith((ref) => client),
            isAuthenticatedProvider2.overrideWith((ref) => true),
            isOnlineProvider.overrideWith((ref) => true),
            hiveBoxesProvider.overrideWith((ref) => boxes),
            optimizedStorageServiceProvider.overrideWithValue(storage),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await secondDb.close();
        });

        final engine = container.read(syncEngineProvider.notifier);
        final firstDrain = engine.drainOutbox();
        await firstMigrationGate.firstReadStarted.future;

        container.read(activeDbProvider.notifier).set(secondDb);
        container.read(syncEngineProvider);
        final secondDrain = engine.drainNow();
        await Future<void>.delayed(Duration.zero);

        check(firstMigrationGate.taskMigrationFlagReads).equals(1);
        check(secondMigrationGate.taskMigrationFlagReads).equals(0);

        firstMigrationGate.releaseFirstRead.complete();
        await secondMigrationGate.firstReadStarted.future;
        secondMigrationGate.releaseFirstRead.complete();
        await firstDrain;
        await secondDrain;

        check(secondMigrationGate.taskMigrationFlagReads).equals(1);
        check(
          await firstDb.syncMetaDao.getValue('hive_caches_migrated'),
        ).isNull();
        check(
          await secondDb.syncMetaDao.getValue('hive_caches_migrated'),
        ).equals('1');
      },
    );

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

    test(
      'ignores stale note feature results after the active database changes',
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

        final gate = Completer<void>();
        client.notesFeatureEnabled = false;
        client.noteListGate = gate.future;
        final engine = container.read(syncEngineProvider.notifier);

        check(container.read(notesFeatureEnabledProvider)).isTrue();
        final resultFuture = engine.requestPull(
          reason: 'switch-during-note-feature',
        );
        await waitFor(() => client.noteListRequests > 0);

        container.read(activeDbProvider.notifier).set(secondDb);
        container.read(syncEngineProvider);

        gate.complete();
        final result = await resultFuture;

        check(result).isNull();
        check(container.read(notesFeatureEnabledProvider)).isTrue();
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

    test(
      'dependency refresh during an active drain keeps the same drainer',
      () async {
        await seedLocalCreate('local:c2', contentHash: 'h2');
        final clockProvider =
            NotifierProvider<_MutableValue<SyncClock>, SyncClock>(
              () => _MutableValue<SyncClock>(const _FixedClock(1)),
            );
        final container = makeContainer(
          clockBuilder: (ref) => ref.watch(clockProvider),
        );
        final engine = container.read(syncEngineProvider.notifier);

        final gate = Completer<void>();
        client.createChatGate = gate.future;

        final firstDrain = engine.drainOutbox();
        await waitFor(() => client.createChatStarts.isNotEmpty);
        check(client.createChatCalls).equals(1);

        container.read(clockProvider.notifier).set(const _FixedClock(2));
        final secondDrain = engine.drainNow();

        gate.complete();
        await firstDrain;
        await secondDrain;
        await engine.drainNow();

        check(client.createChatCalls).equals(1);
        check(await db.outboxDao.pendingForChat('local:c2')).isEmpty();
      },
    );

    test(
      'database switch during an active claim does not post stale outbox work',
      () async {
        await db.close();
        final claimGate = _GateFirstOutboxClaim();
        final firstDb = AppDatabase(
          NativeDatabase.memory().interceptWith(claimGate),
        );
        db = firstDb;
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

        await seedLocalCreate('local:stale-db', contentHash: 'h-stale-db');
        final engine = container.read(syncEngineProvider.notifier);

        final drain = engine.drainOutbox();
        await claimGate.claimStarted.future;

        container.read(activeDbProvider.notifier).set(secondDb);
        container.read(syncEngineProvider);
        check(engine.hasCachedDrainerForTesting).isFalse();

        claimGate.releaseClaim.complete();
        await drain;

        check(client.createChatCalls).equals(0);
        final pending = await firstDb.outboxDao.pendingForChat(
          'local:stale-db',
        );
        check(pending).length.equals(1);
        check(pending.single.lastError).equals('offline');
      },
    );

    test('auth flip during an active drain drops the cached drainer', () async {
      await seedLocalCreate(
        'local:auth-flip',
        contentHash: 'h-auth-flip',
        completion: const RequestCompletionPayload(
          assistantMessageId: 'assistant-1',
          model: 'model-1',
        ),
      );
      final authProvider = NotifierProvider<_MutableValue<bool>, bool>(
        () => _MutableValue<bool>(true),
      );
      final completionRunner = _RecordingCompletionRunner();
      final container = makeContainer(
        authBuilder: (ref) => ref.watch(authProvider),
        completionRunner: completionRunner,
      );
      final engine = container.read(syncEngineProvider.notifier);
      final remapEvents = <RemapEvent>[];
      final remapSub = engine.remapEvents.listen(remapEvents.add);
      addTearDown(remapSub.cancel);

      final gate = Completer<void>();
      client.createChatGate = gate.future;

      final drain = engine.drainOutbox();
      await waitFor(() => client.createChatStarts.isNotEmpty);
      final firstRemapper = engine.remapperForTesting;
      check(firstRemapper).isNotNull();
      check(engine.hasCachedDrainerForTesting).isTrue();

      container.read(authProvider.notifier).set(false);
      container.read(syncEngineProvider);

      check(engine.hasCachedDrainerForTesting).isFalse();
      check(engine.hasCachedRemapperForTesting).isFalse();
      gate.complete();
      await drain;

      check(remapEvents).length.equals(1);
      check(remapEvents.single.fromId).equals('local:auth-flip');
      check(remapEvents.single.entityKind).equals('chat');
      container.read(authProvider.notifier).set(true);
      container.read(syncEngineProvider);
      final secondRemapper = engine.remapperForTesting;
      check(secondRemapper).isNotNull();
      check(identical(firstRemapper, secondRemapper)).isFalse();
      check(client.createChatCalls).equals(1);
      check(completionRunner.calls).isEmpty();
    });

    test(
      'completion runner rebind keeps preserved drainer from using stale runner',
      () async {
        await seedLocalCreate(
          'local:runner-rebind',
          contentHash: 'h-runner-rebind',
          completion: const RequestCompletionPayload(
            assistantMessageId: 'assistant-1',
            model: 'model-1',
          ),
        );
        final firstRunner = _RecordingCompletionRunner();
        final secondRunner = _RecordingCompletionRunner();
        final completionProvider =
            NotifierProvider<
              _MutableValue<RequestCompletionRunner>,
              RequestCompletionRunner
            >(() => _MutableValue<RequestCompletionRunner>(firstRunner));
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            syncApiClientProvider.overrideWith((ref) => client),
            isAuthenticatedProvider2.overrideWith((ref) => true),
            isOnlineProvider.overrideWith((ref) => true),
            requestCompletionRunnerProvider.overrideWith(
              (ref) => ref.watch(completionProvider),
            ),
          ],
        );
        addTearDown(container.dispose);
        final engine = container.read(syncEngineProvider.notifier);

        final gate = Completer<void>();
        client.createChatGate = gate.future;
        final drain = engine.drainOutbox();
        await waitFor(() => client.createChatStarts.isNotEmpty);

        container.read(completionProvider.notifier).set(secondRunner);
        container.read(syncEngineProvider);
        gate.complete();
        await drain;

        check(firstRunner.calls).isEmpty();
        check(secondRunner.calls).isEmpty();

        await engine.drainNow();

        check(firstRunner.calls).isEmpty();
        check(secondRunner.calls).length.equals(1);
      },
    );

    test(
      'disposing during an active create keeps remap forwarding until drain ends',
      () async {
        await seedLocalCreate(
          'local:dispose-remap',
          contentHash: 'h-dispose-remap',
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => db),
            syncApiClientProvider.overrideWith((ref) => client),
            isAuthenticatedProvider2.overrideWith((ref) => true),
            isOnlineProvider.overrideWith((ref) => true),
          ],
        );
        final engine = container.read(syncEngineProvider.notifier);
        final remapEvents = <RemapEvent>[];
        final remapSub = engine.remapEvents.listen(remapEvents.add);
        addTearDown(remapSub.cancel);

        final gate = Completer<void>();
        client.createChatGate = gate.future;
        final drain = engine.drainOutbox();
        await waitFor(() => client.createChatStarts.isNotEmpty);

        container.dispose();
        gate.complete();
        await drain;

        check(remapEvents).length.equals(1);
        check(remapEvents.single.fromId).equals('local:dispose-remap');
        check(engine.hasCachedDrainerForTesting).isFalse();
        check(engine.hasCachedRemapperForTesting).isFalse();
      },
    );

    test(
      'disposing after auth flip keeps retired remap forwarding until drain ends',
      () async {
        await seedLocalCreate(
          'local:auth-dispose-remap',
          contentHash: 'h-auth-dispose-remap',
        );
        final authProvider = NotifierProvider<_MutableValue<bool>, bool>(
          () => _MutableValue<bool>(true),
        );
        final container = makeContainer(
          authBuilder: (ref) => ref.watch(authProvider),
        );
        final engine = container.read(syncEngineProvider.notifier);
        final remapEvents = <RemapEvent>[];
        final remapSub = engine.remapEvents.listen(remapEvents.add);
        addTearDown(remapSub.cancel);

        final gate = Completer<void>();
        client.createChatGate = gate.future;
        final drain = engine.drainOutbox();
        await waitFor(() => client.createChatStarts.isNotEmpty);

        container.read(authProvider.notifier).set(false);
        container.read(syncEngineProvider);
        check(engine.hasCachedDrainerForTesting).isFalse();
        check(engine.hasCachedRemapperForTesting).isFalse();

        container.dispose();
        gate.complete();
        await drain;

        check(remapEvents).length.equals(1);
        check(remapEvents.single.fromId).equals('local:auth-dispose-remap');
        check(engine.hasCachedDrainerForTesting).isFalse();
        check(engine.hasCachedRemapperForTesting).isFalse();
      },
    );

    test(
      'pull-cycle drain clears a stale drainer after dependency refresh',
      () async {
        await seedLocalCreate('local:pull-stale', contentHash: 'h-pull-stale');
        final clockProvider =
            NotifierProvider<_MutableValue<SyncClock>, SyncClock>(
              () => _MutableValue<SyncClock>(const _FixedClock(1)),
            );
        final container = makeContainer(
          clockBuilder: (ref) => ref.watch(clockProvider),
        );
        final engine = container.read(syncEngineProvider.notifier);

        final gate = Completer<void>();
        client.createChatGate = gate.future;

        final pull = engine.requestPull(reason: 'pull-cycle-stale-drainer');
        await waitFor(() => client.createChatStarts.isNotEmpty);
        check(engine.hasCachedDrainerForTesting).isTrue();

        container.read(clockProvider.notifier).set(const _FixedClock(2));
        container.read(syncEngineProvider);
        check(engine.hasCachedDrainerForTesting).isTrue();

        gate.complete();
        final result = await pull;

        check(result).isNull();
        check(engine.hasCachedDrainerForTesting).isFalse();
        check(client.createChatCalls).equals(1);
      },
    );
  });
}
