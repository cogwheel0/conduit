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
  });

  group('deleteFor', () {
    test(
      'closes the active database and deletes db + wal + shm files',
      () async {
        final db = manager.openFor(_server('alpha'));
        await db.customSelect('SELECT 1').get();

        final base = fileFor(DatabaseManager.fileNameFor('alpha'));
        check(base.existsSync()).isTrue();
        // Simulate leftover WAL artifacts (present while a database is in WAL
        // mode, and after unclean shutdowns).
        File('${base.path}-wal').writeAsStringSync('wal');
        File('${base.path}-shm').writeAsStringSync('shm');

        await manager.deleteFor('alpha');

        check(base.existsSync()).isFalse();
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
