import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_manager.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'openwebui_mcp_app.dart';

typedef McpAppCacheEntry = ({OpenWebUiMcpAppResource resource, double height});

final mcpAppResourceCacheProvider = Provider((ref) {
  ref.watch(apiServiceProvider);
  ref.watch(openWebUiAuthSessionEpochProvider);
  final database = ref.watch(appDatabaseProvider);
  final cache = McpAppResourceCache(
    database: database,
    manager: database == null ? null : ref.read(databaseManagerProvider),
  );
  ref.onDispose(cache.dispose);
  return cache;
});

/// The invocation cache, backed by the existing account-private cache table.
/// Account sign-out/removal purges its database through the normal lifecycle.
class McpAppResourceCache {
  McpAppResourceCache({AppDatabase? database, DatabaseManager? manager})
    : _database = database,
      _manager = manager {
    ready = _queue(_load);
  }

  static String? keyFor(String? cacheId, OpenWebUiMcpApp app) {
    if (cacheId == null) return null;
    final identity = jsonEncode([
      cacheId,
      app.serverId,
      app.toolName,
      app.binding,
      app.arguments,
      app.result,
    ]);
    return sha256.convert(utf8.encode(identity)).toString();
  }

  static const _prefix = 'mcp_app_resource:';
  static const _maxEntries = 32;
  static const _maxBytes = 20 * 1024 * 1024;
  final AppDatabase? _database;
  final DatabaseManager? _manager;
  final _entries = <String, McpAppCacheEntry>{};
  final _sizes = <String, int>{};
  final _heightWrites = <String, Map<String, num>>{};
  int _bytes = 0;
  int _lastUsed = 0;
  bool _disposed = false;
  Future<void> _pending = Future<void>.value();
  late final Future<void> ready;

  Future<void> get settled => _pending;
  McpAppCacheEntry? operator [](String? key) => _entries[key];

  Future<McpAppCacheEntry?> read(String? key) async {
    await ready;
    final entry = _entries.remove(key);
    if (entry == null || _disposed) return null;
    _entries[key!] = entry;
    _heightWrites.remove(key);
    final usedAt = _usedAt();
    unawaited(
      _queue((db) => db.appCacheDao.touch('$_prefix$key', updatedAt: usedAt)),
    );
    return entry;
  }

  void put(String key, McpAppCacheEntry entry) {
    if (_disposed) return;
    final previous = _entries[key];
    if (previous != null && identical(previous.resource, entry.resource)) {
      final size =
          _sizes[key]! +
          jsonEncode(entry.height).length -
          jsonEncode(previous.height).length;
      final evicted = _store(key, entry, size);
      if (_database == null) return;
      final queued = _heightWrites.containsKey(key);
      final pending = _heightWrites.putIfAbsent(key, () => <String, num>{});
      pending['height'] = entry.height;
      pending['usedAt'] = _usedAt();
      if (!queued) {
        unawaited(
          _queue((db) async {
            // Removal/reinsertion may already have queued a different update.
            if (identical(_heightWrites[key], pending)) {
              _heightWrites.remove(key);
            }
            // Updating only the numeric field avoids encoding/queuing HTML on
            // every resize. SQL UPDATE cannot resurrect an evicted resource.
            await db.customUpdate(
              "UPDATE app_cache SET value = json_set(value, '\$.height', json(?)), "
              'updated_at = ? WHERE key = ?',
              variables: [
                Variable.withString(jsonEncode(pending['height'])),
                Variable.withInt(pending['usedAt']!.toInt()),
                Variable.withString('$_prefix$key'),
              ],
              updates: {db.appCache},
            );
          }),
        );
      }
      if (evicted.isNotEmpty) {
        unawaited(
          _queue(
            (db) =>
                db.appCacheDao.deleteKeys(evicted.map((key) => '$_prefix$key')),
          ),
        );
      }
      return;
    }
    final value = jsonEncode({
      'resource': entry.resource.toJson(),
      'height': entry.height,
    });
    final size = utf8.encode('$_prefix$key').length + utf8.encode(value).length;
    if (size > _maxBytes) return;
    _heightWrites.remove(key);
    final evicted = _store(key, entry, size);
    final usedAt = _usedAt();
    unawaited(
      _queue(
        (db) => db.transaction(() async {
          await db.appCacheDao.setValue(
            '$_prefix$key',
            value,
            updatedAt: usedAt,
          );
          if (evicted.isNotEmpty) {
            await db.appCacheDao.deleteKeys(
              evicted.map((key) => '$_prefix$key'),
            );
          }
        }),
      ),
    );
  }

  void remove(String? key) {
    if (_disposed || key == null) return;
    _heightWrites.remove(key);
    _entries.remove(key);
    _bytes -= _sizes.remove(key) ?? 0;
    unawaited(_queue((db) => db.appCacheDao.deleteKey('$_prefix$key')));
  }

  List<String> _store(String key, McpAppCacheEntry entry, int size) {
    _entries.remove(key);
    _bytes -= _sizes[key] ?? 0;
    _entries[key] = entry;
    _sizes[key] = size;
    _bytes += size;
    final evicted = <String>[];
    while (_entries.length > _maxEntries || _bytes > _maxBytes) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest);
      _heightWrites.remove(oldest);
      _bytes -= _sizes.remove(oldest)!;
      evicted.add(oldest);
    }
    return evicted;
  }

  int _usedAt() =>
      _lastUsed = max(DateTime.now().millisecondsSinceEpoch, _lastUsed + 1);

  Future<void> _load(AppDatabase db) async {
    final rows = await db.appCacheDao.entriesWithPrefix(_prefix);
    if (_disposed) return;
    for (final row in rows) {
      _lastUsed = max(_lastUsed, row.updatedAt);
      try {
        final json = jsonDecode(row.value) as Map<String, dynamic>;
        final height = (json['height'] as num).toDouble();
        if (!height.isFinite || height <= 0) continue;
        final resource = OpenWebUiMcpAppResource.fromJson(
          json['resource'] as Map<String, dynamic>,
        );
        final size =
            utf8.encode(row.key).length + utf8.encode(row.value).length;
        if (size <= _maxBytes) {
          _store(row.key.substring(_prefix.length), (
            resource: resource,
            height: height,
          ), size);
        }
      } catch (_) {
        // A malformed cache entry is a miss; the normal RPC/error path remains.
      }
    }
    final discarded = rows.where(
      (row) => !_entries.containsKey(row.key.substring(_prefix.length)),
    );
    if (discarded.isNotEmpty) {
      await db.appCacheDao.deleteKeys(discarded.map((row) => row.key));
    }
  }

  Future<void> _queue(Future<void> Function(AppDatabase) operation) {
    final db = _database;
    if (db == null || _disposed) return Future<void>.value();
    final lease = _manager?.tryAcquireLease(db);
    if (_manager?.serverIdForDatabase(db) != null && lease == null) {
      return Future<void>.value();
    }
    _pending = _pending
        .then((_) async {
          try {
            await operation(db);
          } finally {
            await lease?.release();
          }
        })
        .catchError((Object error) {
          DebugLogger.warning(
            'resource-cache-storage-failed',
            scope: 'chat/mcp-app',
            data: {'errorType': error.runtimeType.toString()},
          );
        });
    return _pending;
  }

  void dispose() {
    _disposed = true;
    _entries.clear();
    _sizes.clear();
    _bytes = 0;
    _heightWrites.clear();
  }
}
