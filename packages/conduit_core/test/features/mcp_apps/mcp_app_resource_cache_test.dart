import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_manager.dart';
import 'package:conduit_core/features/mcp_apps/mcp_app_resource_cache.dart';
import 'package:conduit_core/features/mcp_apps/openwebui_mcp_app.dart';
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
