import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_manager.dart';
import 'package:conduit_core/features/mcp_apps/mcp_app_resource_cache.dart';
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:test/test.dart';

const _resource = OpenWebUiMcpAppResource(
  html: '<h1>Invented itinerary</h1>',
  csp: "default-src 'none'; script-src 'unsafe-inline'",
  additionalCsp: "frame-src 'none'",
  ui: {
    'csp': {
      'resourceDomains': ['https://tiles.example'],
    },
  },
  tool: {'name': 'render_itinerary', 'description': 'Synthetic fixture'},
);

final class _HeldCacheWrites extends QueryInterceptor {
  final started = Completer<void>();
  final release = Completer<void>();
  final argumentSizes = <int>[];
  bool hold = false;

  Future<void> _beforeWrite(String statement, List<Object?> args) async {
    if (!hold || !statement.contains('app_cache')) return;
    argumentSizes.add(args.whereType<String>().fold(0, (n, s) => n + s.length));
    if (!started.isCompleted) started.complete();
    await release.future;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await _beforeWrite(statement, args);
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    await _beforeWrite(statement, args);
    return executor.runUpdate(statement, args);
  }
}

void main() {
  late Directory directory;
  late List<AppDatabase> databases;
  late List<McpAppResourceCache> caches;

  AppDatabase open(String account) {
    final database = AppDatabase(
      NativeDatabase(File('${directory.path}/$account.sqlite')),
    );
    databases.add(database);
    return database;
  }

  Future<McpAppResourceCache> cache(AppDatabase database) async {
    final result = McpAppResourceCache(database: database);
    caches.add(result);
    await result.ready;
    return result;
  }

  setUp(() {
    directory = Directory.systemTemp.createTempSync('conduit_mcp_cache_');
    databases = [];
    caches = [];
  });

  tearDown(() async {
    for (final cache in caches) {
      await cache.settled;
      cache.dispose();
    }
    for (final database in databases) {
      await database.close();
    }
    directory.deleteSync(recursive: true);
  });

  test('restart restores the complete resource and last height', () async {
    const key =
        '7502bf804c126e44228a1afe02aa232aa582aba63fbf98937390dbfc85149c3e';
    final database = open('a');
    final first = await cache(database);
    first.put(key, (resource: _resource, height: 2000));
    first.put(key, (resource: _resource, height: 9935));
    await first.settled;
    expect(
      (await database.appCacheDao.entriesWithPrefix('mcp_app_resource:'))
          .single
          .key,
      'mcp_app_resource:$key',
    );
    first.dispose();
    await database.close();
    databases.remove(database);

    final reopened = await cache(open('a'));
    final entry = await reopened.read(key);
    expect(entry?.resource.toJson(), _resource.toJson());
    expect(entry?.height, 9935);
    expect(await reopened.read('message:invocation:changed-result'), isNull);
  });

  test('resize writes stay small and coalesce behind slow storage', () async {
    final writes = _HeldCacheWrites();
    final database = AppDatabase(NativeDatabase.memory().interceptWith(writes));
    databases.add(database);
    final first = await cache(database);
    final resource = OpenWebUiMcpAppResource(
      html: 'x' * (1024 * 1024),
      csp: _resource.csp,
    );
    first.put('call', (resource: resource, height: 300));
    await first.settled;
    writes.hold = true;
    addTearDown(() {
      if (!writes.release.isCompleted) writes.release.complete();
    });
    first.put('call', (resource: resource, height: 2000));
    await writes.started.future;
    for (var height = 2100; height < 2200; height++) {
      first.put('call', (resource: resource, height: height.toDouble()));
    }
    writes.release.complete();
    await first.settled;
    expect(writes.argumentSizes, hasLength(lessThanOrEqualTo(2)));
    expect(writes.argumentSizes, everyElement(lessThan(100)));
    first.dispose();
    final restored = await (await cache(database)).read('call');
    expect(restored?.height, 2199);
    expect(restored?.resource.html, resource.html);
  });

  for (final operation in ['removal', 'eviction', 'read']) {
    test('pending height writes stay ordered after $operation', () async {
      final writes = _HeldCacheWrites();
      final database = AppDatabase(
        NativeDatabase(File('${directory.path}/a.sqlite'))
            .interceptWith(writes),
      );
      databases.add(database);
      final first = await cache(database);
      first.put('call', (resource: _resource, height: 300));
      await first.settled;
      writes.hold = true;
      addTearDown(() {
        if (!writes.release.isCompleted) writes.release.complete();
      });
      first.put('blocker', (resource: _resource, height: 300));
      await writes.started.future;
      first.put('call', (resource: _resource, height: 400));
      if (operation == 'eviction') {
        for (var i = 0; i < 32; i++) {
          first.put('other-$i', (resource: _resource, height: 300));
        }
      } else if (operation == 'removal') {
        first.remove('call');
      } else {
        await first.read('call');
        first.put('other', (resource: _resource, height: 300));
      }
      first.put('call', (resource: _resource, height: 500));
      first.put('call', (resource: _resource, height: 600));
      writes.release.complete();
      await first.settled;
      final rows = await database.appCacheDao.entriesWithPrefix(
        'mcp_app_resource:',
      );
      expect(rows.last.key, 'mcp_app_resource:call');
      first.dispose();
      await database.close();
      databases.remove(database);
      final restored = await (await cache(open('a'))).read('call');
      expect(restored?.height, 600);
      expect(restored?.resource.toJson(), _resource.toJson());
    });
  }

  test('explicit removal survives restart and keeps other entries', () async {
    final database = open('a');
    final first = await cache(database);
    first.put('failed', (resource: _resource, height: 300));
    first.put('keep', (resource: _resource, height: 9935));
    first.remove('failed');
    await first.settled;
    first.dispose();
    final reopened = await cache(database);
    expect(await reopened.read('failed'), isNull);
    expect((await reopened.read('keep'))?.height, 9935);
  });

  test('32-entry LRU and recent reads survive a restart', () async {
    final database = open('a');
    final first = await cache(database);
    for (var i = 0; i < 32; i++) {
      first.put('call-$i', (resource: _resource, height: 300));
    }
    await first.read('call-0');
    await first.settled;
    first.dispose();
    final reopened = await cache(database);
    reopened.put('call-32', (resource: _resource, height: 300));
    await reopened.settled;
    expect(await reopened.read('call-0'), isNotNull);
    expect(await reopened.read('call-1'), isNull);
    expect(await reopened.read('call-32'), isNotNull);
    expect(
      await database.appCacheDao.entriesWithPrefix('mcp_app_resource:'),
      hasLength(32),
    );
  });

  test(
    'UTF-8 byte limit evicts old resources and bypasses oversized ones',
    () async {
      final database = open('a');
      final first = await cache(database);
      final large = OpenWebUiMcpAppResource(
        html: 'λ' * (6 * 1024 * 1024),
        csp: _resource.csp,
      );
      first.put('old', (resource: large, height: 2000));
      first.put('recent', (resource: large, height: 10000));
      first.put('oversized', (
        resource: OpenWebUiMcpAppResource(
          html: 'x' * (21 * 1024 * 1024),
          csp: _resource.csp,
        ),
        height: 10000,
      ));
      await first.settled;
      expect(await first.read('old'), isNull);
      expect(await first.read('recent'), isNotNull);
      expect(await first.read('oversized'), isNull);
      final rows = await database.appCacheDao.entriesWithPrefix(
        'mcp_app_resource:',
      );
      expect(rows, hasLength(1));
      expect(
        utf8.encode(rows.single.key).length +
            utf8.encode(rows.single.value).length,
        lessThanOrEqualTo(20 * 1024 * 1024),
      );
      first.dispose();
      expect((await (await cache(database)).read('recent'))?.height, 10000);
    },
  );

  test('the same invocation stays private to its account database', () async {
    final a = open('a');
    final first = await cache(a);
    first.put('same-invocation', (resource: _resource, height: 8000));
    await first.settled;
    first.dispose();
    final second = await cache(open('b'));
    expect(await second.read('same-invocation'), isNull);
    second.put('same-invocation', (
      resource: const OpenWebUiMcpAppResource(
        html: '<p>Account B fixture</p>',
        csp: "default-src 'none'",
      ),
      height: 100,
    ));
    expect((await (await cache(a)).read('same-invocation'))?.height, 8000);
  });

  test(
    'malformed entries and missing CSP are misses; unrelated caches stay',
    () async {
      final database = open('a');
      await database.appCacheDao.setValue('other-feature', 'keep');
      await database.appCacheDao.setValue('mcp_app_resource:bad-json', '{');
      await database.appCacheDao.setValue(
        'mcp_app_resource:no-csp',
        jsonEncode({
          'resource': {'html': '<p>unsafe</p>'},
          'height': 300,
        }),
      );
      final restored = await cache(database);
      expect(await restored.read('bad-json'), isNull);
      expect(await restored.read('no-csp'), isNull);
      expect(
        await database.appCacheDao.entriesWithPrefix('mcp_app_resource:'),
        isEmpty,
      );
      expect(await database.appCacheDao.getValue('other-feature'), 'keep');
    },
  );

  test(
    'account purge drains pending writes and removes the cached resource',
    () async {
      final manager = DatabaseManager(
        databaseDirectory: () async => directory,
        openDatabase: (name) =>
            AppDatabase(NativeDatabase(File('${directory.path}/$name.sqlite'))),
      );
      addTearDown(manager.closeActive);
      final database = manager.openForServerId('a');
      final first = McpAppResourceCache(database: database, manager: manager);
      caches.add(first);
      await first.ready;
      first.put('call', (resource: _resource, height: 2000));
      first.put('call', (resource: _resource, height: 10000));
      first.dispose();
      await manager.deleteFor('a');
      await first.settled;
      final reopened = McpAppResourceCache(
        database: manager.openForServerId('a'),
        manager: manager,
      );
      caches.add(reopened);
      await reopened.ready;
      expect(await reopened.read('call'), isNull);
    },
  );
}
