import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/database/database_manager.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

ServerConfig _server(String id) =>
    ServerConfig(id: id, name: 'Server $id', url: 'https://$id.example');

final class _CloseFailingDatabase extends AppDatabase {
  _CloseFailingDatabase(super.executor);

  bool failClose = true;
  int closeAttempts = 0;
  Completer<void>? closeGate;

  @override
  Future<void> close() async {
    closeAttempts += 1;
    final gate = closeGate;
    closeGate = null;
    if (gate != null) await gate.future;
    if (failClose) {
      throw StateError('injected close failure #$closeAttempts');
    }
    await super.close();
  }
}

void main() {
  late Directory tempDir;
  late List<String> openedFileNames;
  late DatabaseManager manager;

  /// Mirrors drift_flutter's `driftDatabase(name:)` location:
  /// `<directory>/<name>.sqlite`, but against a temp dir and without
  /// platform channels.
  File fileFor(String fileName) =>
      File(p.join(tempDir.path, '$fileName.sqlite'));

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('conduit_db_test');
    openedFileNames = [];
    manager = DatabaseManager(
      databaseDirectory: () async => tempDir,
      openDatabase: (fileName) {
        openedFileNames.add(fileName);
        return AppDatabase(NativeDatabase(fileFor(fileName)));
      },
    );
  });

  tearDown(() async {
    await manager.closeActive();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('openFor', () {
    test('returns the cached instance for the same server id', () async {
      final first = manager.openFor(_server('alpha'));
      final second = manager.openFor(_server('alpha'));
      check(identical(first, second)).isTrue();
      check(openedFileNames.length).equals(1);
    });

    test('switching servers closes the previous database', () async {
      final first = manager.openFor(_server('alpha'));
      // Force the lazy executor open so close() has something to tear down.
      await first.customSelect('SELECT 1').get();

      final second = manager.openFor(_server('beta'));
      check(identical(first, second)).isFalse();

      // The close is fire-and-forget; poll until the old database refuses
      // work.
      await _waitForClosed(first);
      // The new database stays usable.
      check((await second.customSelect('SELECT 1 AS one').get())).isNotEmpty();
    });

    test('distinct servers map to distinct database files', () async {
      final first = manager.openFor(_server('alpha'));
      await first.customSelect('SELECT 1').get();
      final second = manager.openFor(_server('beta'));
      await second.customSelect('SELECT 1').get();

      check(openedFileNames.toSet().length).equals(2);
      check(
        fileFor(DatabaseManager.fileNameFor('alpha')).existsSync(),
      ).isTrue();
      check(fileFor(DatabaseManager.fileNameFor('beta')).existsSync()).isTrue();
    });

    test(
      'rapid switch-back defers until close before opening a new executor',
      () async {
        await manager.closeActive();
        final databases = <String, List<_CloseFailingDatabase>>{};
        manager = DatabaseManager(
          databaseDirectory: () async => tempDir,
          openDatabase: (fileName) {
            final database = _CloseFailingDatabase(
              NativeDatabase(fileFor(fileName)),
            )..failClose = false;
            databases.putIfAbsent(fileName, () => []).add(database);
            return database;
          },
        );

        final alphaFile = DatabaseManager.fileNameFor('alpha');
        final originalAlpha = manager.openFor(_server('alpha'));
        await originalAlpha.customSelect('SELECT 1').get();
        final alphaCloseGate = Completer<void>();
        databases[alphaFile]!.single.closeGate = alphaCloseGate;

        manager.openFor(_server('beta'));
        await _waitForCloseAttempts(databases[alphaFile]!.single, 1);

        final deferred = manager.openForIfReady(_server('alpha'));
        check(deferred is DatabaseOpenDeferred).isTrue();
        check(databases[alphaFile]!.length).equals(1);

        alphaCloseGate.complete();
        await (deferred as DatabaseOpenDeferred).retryAfter;

        final reopened = manager.openForIfReady(_server('alpha'));
        check(reopened is DatabaseOpenReady).isTrue();
        final reopenedAlpha = (reopened as DatabaseOpenReady).database;
        check(identical(reopenedAlpha, originalAlpha)).isFalse();
        check(databases[alphaFile]!.length).equals(2);
        check(
          (await reopenedAlpha.customSelect('SELECT 1').get()),
        ).isNotEmpty();
      },
    );
  });

  group('lifetime leases', () {
    test(
      'managed provenance survives physical close for detached lease guards',
      () async {
        await manager.closeActive();
        late _CloseFailingDatabase database;
        manager = DatabaseManager(
          databaseDirectory: () async => tempDir,
          openDatabase: (fileName) {
            database = _CloseFailingDatabase(NativeDatabase(fileFor(fileName)))
              ..failClose = false;
            return database;
          },
        );

        final opened = manager.openFor(_server('alpha'));
        await opened.customSelect('SELECT 1').get();
        check(manager.serverIdForDatabase(opened)).equals('alpha');
        final closeGate = Completer<void>();
        addTearDown(() {
          if (!closeGate.isCompleted) closeGate.complete();
        });
        database.closeGate = closeGate;

        final close = manager.closeActive();
        await _waitForCloseAttempts(database, 1);

        // Operational ownership is already revoked, so a late callback cannot
        // acquire a lease. Stable provenance must nevertheless remain visible
        // or callers could mistake this executor for an unmanaged test seam
        // and issue SQL while/after it closes.
        check(manager.tryAcquireLease(opened)).isNull();
        check(manager.serverIdForDatabase(opened)).equals('alpha');

        closeGate.complete();
        await close;
        check(manager.tryAcquireLease(opened)).isNull();
        check(manager.serverIdForDatabase(opened)).equals('alpha');
      },
    );

    test(
      'retired database stays usable until its final lease releases',
      () async {
        final first = manager.openFor(_server('alpha'));
        await first.customSelect('SELECT 1').get();
        final lease = manager.tryAcquireLease(first);
        check(lease).isNotNull();

        final second = manager.openFor(_server('beta'));
        check(identical(first, second)).isFalse();
        check((await second.customSelect('SELECT 1').get())).isNotEmpty();
        check((await first.customSelect('SELECT 1').get())).isNotEmpty();

        await lease!.release();
        await _waitForClosed(first);
        check((await second.customSelect('SELECT 1').get())).isNotEmpty();
      },
    );

    test('switching back reuses a leased retired database', () async {
      final first = manager.openFor(_server('alpha'));
      await first.customSelect('SELECT 1').get();
      final lease = manager.tryAcquireLease(first)!;

      manager.openFor(_server('beta'));
      final reopened = manager.openFor(_server('alpha'));

      check(identical(reopened, first)).isTrue();
      check(
        openedFileNames
            .where((name) => name == DatabaseManager.fileNameFor('alpha'))
            .length,
      ).equals(1);
      await lease.release();
      // Releasing an active database does not close it under its caller.
      check((await reopened.customSelect('SELECT 1').get())).isNotEmpty();

      manager.openFor(_server('gamma'));
      await _waitForClosed(first);
    });

    test(
      'closeActive waits for a leased database and release unblocks it',
      () async {
        final db = manager.openFor(_server('alpha'));
        await db.customSelect('SELECT 1').get();
        final lease = manager.tryAcquireLease(db)!;

        var closeCompleted = false;
        final close = manager.closeActive().whenComplete(
          () => closeCompleted = true,
        );
        await Future<void>.delayed(Duration.zero);
        check(closeCompleted).isFalse();
        check((await db.customSelect('SELECT 1').get())).isNotEmpty();
        check(
          manager.openForIfReady(_server('alpha')),
        ).isA<DatabaseOpenDeferred>();
        check(manager.tryAcquireLease(db)).isNull();

        await lease.release();
        await close;
        check(closeCompleted).isTrue();
        await _waitForClosed(db);
      },
    );

    test('an unmanaged database cannot acquire a manager lease', () async {
      final unmanaged = AppDatabase(NativeDatabase.memory());
      addTearDown(unmanaged.close);

      check(manager.tryAcquireLease(unmanaged)).isNull();
    });

    test(
      'lease release and unrelated deletion do not wait for another file close',
      () async {
        await manager.closeActive();
        final databases = <String, _CloseFailingDatabase>{};
        manager = DatabaseManager(
          databaseDirectory: () async => tempDir,
          openDatabase: (fileName) {
            final database = _CloseFailingDatabase(
              NativeDatabase(fileFor(fileName)),
            )..failClose = false;
            databases[fileName] = database;
            return database;
          },
        );

        final alpha = manager.openFor(_server('alpha'));
        await alpha.customSelect('SELECT 1').get();
        final alphaGate = Completer<void>();
        databases[DatabaseManager.fileNameFor('alpha')]!.closeGate = alphaGate;
        addTearDown(() async {
          if (!alphaGate.isCompleted) alphaGate.complete();
          await _waitForClosed(alpha);
        });

        final beta = manager.openFor(_server('beta'));
        await _waitForCloseAttempts(
          databases[DatabaseManager.fileNameFor('alpha')]!,
          1,
        );
        final betaLease = manager.tryAcquireLease(beta)!;
        final gamma = manager.openFor(_server('gamma'));
        await gamma.customSelect('SELECT 1').get();

        // Releasing B is immediate bookkeeping, and B's physical close starts
        // independently even though A's different SQLite file is still stuck.
        var releaseCompleted = false;
        final release = betaLease.release().whenComplete(
          () => releaseCompleted = true,
        );
        await Future<void>.delayed(Duration.zero);
        check(releaseCompleted).isTrue();
        await release;
        await _waitForCloseAttempts(
          databases[DatabaseManager.fileNameFor('beta')]!,
          1,
        );
        check(alphaGate.isCompleted).isFalse();

        // Deleting C likewise awaits only C's exact executor.
        await manager.deleteFor('gamma');
        check(alphaGate.isCompleted).isFalse();
        check(
          fileFor(DatabaseManager.fileNameFor('gamma')).existsSync(),
        ).isFalse();

        alphaGate.complete();
        await _waitForClosed(alpha);
      },
    );
  });

  group('closeActive', () {
    test('closes and forgets the active database', () async {
      final db = manager.openFor(_server('alpha'));
      await db.customSelect('SELECT 1').get();
      await manager.closeActive();
      await _waitForClosed(db);

      // Re-opening the same server yields a fresh instance.
      final reopened = manager.openFor(_server('alpha'));
      check(identical(db, reopened)).isFalse();
      check((await reopened.customSelect('SELECT 1').get())).isNotEmpty();
    });

    test('is a no-op when nothing is open', () async {
      await manager.closeActive();
    });

    test('propagates failure from its own close attempt', () async {
      await manager.closeActive();
      late _CloseFailingDatabase database;
      manager = DatabaseManager(
        databaseDirectory: () async => tempDir,
        openDatabase: (fileName) {
          database = _CloseFailingDatabase(NativeDatabase(fileFor(fileName)));
          return database;
        },
      );

      final opened = manager.openFor(_server('alpha'));
      await opened.customSelect('SELECT 1').get();

      await check(manager.closeActive()).throws<StateError>();
      check(database.closeAttempts).equals(1);

      // A second explicit close retries the exact failed executor; callers do
      // not need to reopen it merely to make cleanup possible.
      database.failClose = false;
      await manager.closeActive();
      check(database.closeAttempts).equals(2);

      final reopened = manager.openFor(_server('alpha'));
      check(identical(reopened, opened)).isFalse();
      check((await reopened.customSelect('SELECT 1').get())).isNotEmpty();
      database.failClose = false;
      await manager.closeActive();
    });

    test(
      'concurrent failed-close retries share and report one attempt',
      () async {
        await manager.closeActive();
        late _CloseFailingDatabase database;
        manager = DatabaseManager(
          databaseDirectory: () async => tempDir,
          openDatabase: (fileName) {
            database = _CloseFailingDatabase(NativeDatabase(fileFor(fileName)));
            return database;
          },
        );

        final opened = manager.openFor(_server('alpha'));
        await opened.customSelect('SELECT 1').get();
        await check(manager.closeActive()).throws<StateError>();

        final retryGate = Completer<void>();
        addTearDown(() {
          if (!retryGate.isCompleted) retryGate.complete();
        });
        database.closeGate = retryGate;
        final firstRetry = manager.closeActive();
        final firstObserved = check(firstRetry).throws<StateError>();
        await _waitForCloseAttempts(database, 2);

        final secondRetry = manager.closeActive();
        final secondObserved = check(secondRetry).throws<StateError>();
        retryGate.complete();

        await Future.wait<void>([firstObserved, secondObserved]);
        check(database.closeAttempts).equals(2);

        database.failClose = false;
        await manager.closeActive();
        check(database.closeAttempts).equals(3);
      },
    );

    test(
      'active close joins an older failed executor and every waiter settles both',
      () async {
        await manager.closeActive();
        final databases = <String, _CloseFailingDatabase>{};
        manager = DatabaseManager(
          databaseDirectory: () async => tempDir,
          openDatabase: (fileName) {
            final database = _CloseFailingDatabase(
              NativeDatabase(fileFor(fileName)),
            );
            databases[fileName] = database;
            return database;
          },
        );
        final alphaFile = DatabaseManager.fileNameFor('alpha');
        final betaFile = DatabaseManager.fileNameFor('beta');

        final alpha = manager.openFor(_server('alpha'));
        await alpha.customSelect('SELECT 1').get();
        await check(manager.closeActive()).throws<StateError>();
        final alphaDatabase = databases[alphaFile]!;

        final beta = manager.openFor(_server('beta'));
        await beta.customSelect('SELECT 1').get();
        final betaDatabase = databases[betaFile]!..failClose = false;
        alphaDatabase.failClose = false;
        final alphaRetryGate = Completer<void>();
        final betaCloseGate = Completer<void>();
        addTearDown(() {
          if (!alphaRetryGate.isCompleted) alphaRetryGate.complete();
          if (!betaCloseGate.isCompleted) betaCloseGate.complete();
        });
        alphaDatabase.closeGate = alphaRetryGate;
        betaDatabase.closeGate = betaCloseGate;

        var firstCompleted = false;
        final first = manager.closeActive().whenComplete(
          () => firstCompleted = true,
        );
        await _waitForCloseAttempts(alphaDatabase, 2);
        await _waitForCloseAttempts(betaDatabase, 1);

        var joinedCompleted = false;
        final joined = manager.closeActive().whenComplete(
          () => joinedCompleted = true,
        );
        betaCloseGate.complete();
        await Future<void>.delayed(Duration.zero);
        check(firstCompleted).isFalse();
        check(joinedCompleted).isFalse();

        alphaRetryGate.complete();
        await Future.wait<void>([first, joined]);
        check(alphaDatabase.closeAttempts).equals(2);
        check(betaDatabase.closeAttempts).equals(1);
      },
    );
  });

  group('deleteFor', () {
    test(
      'cannot reopen a server while deletion waits for its final lease',
      () async {
        final original = manager.openFor(_server('alpha'));
        await original.customSelect('SELECT 1').get();
        final lease = manager.tryAcquireLease(original)!;
        final base = fileFor(DatabaseManager.fileNameFor('alpha'));

        final deletion = manager.deleteFor('alpha');
        final duplicateDeletion = manager.deleteFor('alpha');
        check(identical(deletion, duplicateDeletion)).isTrue();
        await Future<void>.delayed(Duration.zero);

        // Once deleteFor owns the path, stale holders cannot extend its lease
        // set and keep account isolation pending indefinitely.
        check(manager.tryAcquireLease(original)).isNull();

        AppDatabase? reopened;
        Object? reopenError;
        try {
          reopened = manager.openFor(_server('alpha'));
          await reopened.customSelect('SELECT 1').get();
        } catch (error) {
          reopenError = error;
        }

        await lease.release();
        await deletion;

        // Before the deletion tombstone existed, [reopened] was a live second
        // executor here even though its SQLite path had just been unlinked.
        check(reopened != null && !base.existsSync()).isFalse();
        check(reopened).isNull();
        check(reopenError is StateError).isTrue();
        check(base.existsSync()).isFalse();

        // Once deletion has settled, a clean reopen is allowed and creates a
        // real backing file instead of retaining an executor to an unlinked
        // inode.
        final cleanReopen = manager.openFor(_server('alpha'));
        await cleanReopen.customSelect('SELECT 1').get();
        check(base.existsSync()).isTrue();
      },
    );

    test(
      'closes the active database and deletes db + journal + wal + shm files',
      () async {
        final db = manager.openFor(_server('alpha'));
        await db.customSelect('SELECT 1').get();

        final base = fileFor(DatabaseManager.fileNameFor('alpha'));
        check(base.existsSync()).isTrue();
        // Simulate leftover WAL artifacts (present while a database is in WAL
        // mode, and after unclean shutdowns) plus SQLite's rollback journal.
        File('${base.path}-journal').writeAsStringSync('journal');
        File('${base.path}-wal').writeAsStringSync('wal');
        File('${base.path}-shm').writeAsStringSync('shm');

        await manager.deleteFor('alpha');

        check(base.existsSync()).isFalse();
        check(File('${base.path}-journal').existsSync()).isFalse();
        check(File('${base.path}-wal').existsSync()).isFalse();
        check(File('${base.path}-shm').existsSync()).isFalse();
        await _waitForClosed(db);
      },
    );

    test(
      'deletes a non-active server\'s files without touching the active db',
      () async {
        final active = manager.openFor(_server('beta'));
        await active.customSelect('SELECT 1').get();

        final stale = fileFor(DatabaseManager.fileNameFor('alpha'));
        stale.writeAsStringSync('old db');
        File('${stale.path}-wal').writeAsStringSync('wal');

        await manager.deleteFor('alpha');

        check(stale.existsSync()).isFalse();
        check(File('${stale.path}-wal').existsSync()).isFalse();
        check((await active.customSelect('SELECT 1').get())).isNotEmpty();
      },
    );

    test('is a no-op when no files exist', () async {
      await manager.deleteFor('never-opened');
    });

    test(
      'retries failed closes without racing deletion or opening a second db',
      () async {
        await manager.closeActive();
        late _CloseFailingDatabase database;
        manager = DatabaseManager(
          databaseDirectory: () async => tempDir,
          openDatabase: (fileName) {
            database = _CloseFailingDatabase(NativeDatabase(fileFor(fileName)));
            return database;
          },
        );

        final opened = manager.openFor(_server('alpha'));
        await opened.customSelect('SELECT 1').get();
        final base = fileFor(DatabaseManager.fileNameFor('alpha'));
        check(base.existsSync()).isTrue();

        await check(manager.deleteFor('alpha')).throws<StateError>();
        check(base.existsSync()).isTrue();
        check(database.closeAttempts).equals(1);

        // An actual retry failure is propagated too; the manager does not
        // treat the stale first error as proof that the file is safe to unlink.
        await check(manager.deleteFor('alpha')).throws<StateError>();
        check(base.existsSync()).isTrue();
        check(database.closeAttempts).equals(2);

        database.failClose = false;
        final retryGate = Completer<void>();
        database.closeGate = retryGate;
        final deletion = manager.deleteFor('alpha');
        final duplicateDeletion = manager.deleteFor('alpha');
        check(identical(deletion, duplicateDeletion)).isTrue();
        await _waitForCloseAttempts(database, 3);

        // The failed executor remains the file owner while its close retry is
        // in flight, so open cannot create a competing connection.
        check(() => manager.openFor(_server('alpha'))).throws<StateError>();
        check(base.existsSync()).isTrue();

        retryGate.complete();
        await deletion;
        check(base.existsSync()).isFalse();

        final cleanReopen = manager.openFor(_server('alpha'));
        check(identical(opened, cleanReopen)).isFalse();
        database.failClose = false;
        check((await cleanReopen.customSelect('SELECT 1').get())).isNotEmpty();
      },
    );

    test(
      'delete and close callers both observe a shared retry failure',
      () async {
        await manager.closeActive();
        late _CloseFailingDatabase database;
        manager = DatabaseManager(
          databaseDirectory: () async => tempDir,
          openDatabase: (fileName) {
            database = _CloseFailingDatabase(NativeDatabase(fileFor(fileName)));
            return database;
          },
        );

        final opened = manager.openFor(_server('alpha'));
        await opened.customSelect('SELECT 1').get();
        await check(manager.closeActive()).throws<StateError>();
        final base = fileFor(DatabaseManager.fileNameFor('alpha'));

        final retryGate = Completer<void>();
        addTearDown(() {
          if (!retryGate.isCompleted) retryGate.complete();
        });
        database.closeGate = retryGate;
        final deletion = manager.deleteFor('alpha');
        final deletionObserved = check(deletion).throws<StateError>();
        await _waitForCloseAttempts(database, 2);

        final close = manager.closeActive();
        final closeObserved = check(close).throws<StateError>();
        retryGate.complete();

        await Future.wait<void>([deletionObserved, closeObserved]);
        check(database.closeAttempts).equals(2);
        check(base.existsSync()).isTrue();

        database.failClose = false;
        await manager.deleteFor('alpha');
        check(database.closeAttempts).equals(3);
        check(base.existsSync()).isFalse();
      },
    );

    test(
      'delete-owned initial close is joined by concurrent close callers',
      () async {
        await manager.closeActive();
        late _CloseFailingDatabase database;
        manager = DatabaseManager(
          databaseDirectory: () async => tempDir,
          openDatabase: (fileName) {
            database = _CloseFailingDatabase(NativeDatabase(fileFor(fileName)));
            return database;
          },
        );

        final opened = manager.openFor(_server('alpha'));
        await opened.customSelect('SELECT 1').get();
        final closeGate = Completer<void>();
        addTearDown(() {
          if (!closeGate.isCompleted) closeGate.complete();
        });
        database.closeGate = closeGate;

        final deletion = manager.deleteFor('alpha');
        final deletionObserved = check(deletion).throws<StateError>();
        await _waitForCloseAttempts(database, 1);

        // deleteFor has already removed the executor from the active slot, but
        // closeActive must still join that explicit physical close rather than
        // report success while the deletion-owned attempt is unresolved.
        final concurrentClose = manager.closeActive();
        final closeObserved = check(concurrentClose).throws<StateError>();
        closeGate.complete();

        await Future.wait<void>([deletionObserved, closeObserved]);
        check(database.closeAttempts).equals(1);

        // The shared failed executor remains retryable for privacy cleanup.
        database.failClose = false;
        await manager.deleteFor('alpha');
        check(database.closeAttempts).equals(2);
      },
    );

    test('reuses the exact executor after a background close fails', () async {
      await manager.closeActive();
      late _CloseFailingDatabase alphaDatabase;
      var openCount = 0;
      manager = DatabaseManager(
        databaseDirectory: () async => tempDir,
        openDatabase: (fileName) {
          openCount += 1;
          final database = _CloseFailingDatabase(
            NativeDatabase(fileFor(fileName)),
          );
          database.failClose = openCount == 1;
          if (openCount == 1) alphaDatabase = database;
          return database;
        },
      );

      final opened = manager.openFor(_server('alpha'));
      await opened.customSelect('SELECT 1').get();
      final closeGate = Completer<void>();
      alphaDatabase.closeGate = closeGate;
      manager.openFor(_server('beta'));
      await _waitForCloseAttempts(alphaDatabase, 1);

      check(() => manager.openFor(_server('alpha'))).throws<StateError>();
      check(openCount).equals(2);
      closeGate.complete();

      final recovered = await _waitForOpen(manager, 'alpha');
      check(identical(opened, recovered)).isTrue();
      check(openCount).equals(2); // alpha and beta; no second alpha executor.
      check((await recovered.customSelect('SELECT 1').get())).isNotEmpty();

      alphaDatabase.failClose = false;
      await manager.closeActive();
    });
  });

  group('fileNameFor', () {
    test('encodes server ids without filename collisions', () {
      final slash = DatabaseManager.fileNameFor('server/a');
      final question = DatabaseManager.fileNameFor('server?a');

      check(slash == question).isFalse();
      check(slash.startsWith('server_')).isTrue();
      check(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(slash)).isTrue();
    });

    test('supports a fixed filename for an independent database', () async {
      await manager.closeActive();
      openedFileNames.clear();
      manager = DatabaseManager(
        databaseDirectory: () async => tempDir,
        openDatabase: (fileName) {
          openedFileNames.add(fileName);
          return AppDatabase(NativeDatabase(fileFor(fileName)));
        },
        databaseFileName: (_) => 'direct_local_v1',
      );

      final db = manager.openForServerId('logical-direct-id');
      await db.customSelect('SELECT 1').get();

      check(openedFileNames).deepEquals(['direct_local_v1']);
      check(fileFor('direct_local_v1').existsSync()).isTrue();

      await manager.deleteFor('logical-direct-id');
      check(fileFor('direct_local_v1').existsSync()).isFalse();
    });

    test('rejects two logical ids that resolve to one filename', () async {
      await manager.closeActive();
      manager = DatabaseManager(
        databaseDirectory: () async => tempDir,
        openDatabase: (fileName) =>
            AppDatabase(NativeDatabase(fileFor(fileName))),
        databaseFileName: (_) => 'shared_name',
      );

      final active = manager.openForServerId('logical-a');
      await active.customSelect('SELECT 1').get();

      check(() => manager.openForServerId('logical-b')).throws<StateError>();
      await check(manager.deleteFor('logical-b')).throws<StateError>();
      check((await active.customSelect('SELECT 1').get())).isNotEmpty();
      check(fileFor('shared_name').existsSync()).isTrue();
    });
  });
}

/// Polls until [db] rejects queries because its executor was closed.
Future<void> _waitForClosed(AppDatabase db) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    try {
      await db.customSelect('SELECT 1').get();
    } catch (_) {
      return; // Closed.
    }
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('database was never closed');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitForCloseAttempts(
  _CloseFailingDatabase database,
  int expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (database.closeAttempts < expected) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'database made ${database.closeAttempts} close attempts; '
        'expected $expected',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<AppDatabase> _waitForOpen(
  DatabaseManager manager,
  String serverId,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    try {
      return manager.openFor(_server(serverId));
    } on StateError {
      if (DateTime.now().isAfter(deadline)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
