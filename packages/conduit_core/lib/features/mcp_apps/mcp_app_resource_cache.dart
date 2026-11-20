import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' show Variable;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_manager.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'openwebui_mcp_app.dart';

typedef McpAppCacheEntry = ({OpenWebUiMcpAppResource resource, double height});

/// Asks [client] for an app's page.
typedef McpAppResourceFetch = Future<OpenWebUiMcpAppResource> Function(
  ApiService client,
  CancelToken token,
);

final mcpAppResourceCacheProvider = Provider((ref) {
  // One cache per signed-in account. A new API client for the same account,
  // such as after a token refresh, keeps it and the apps it serves.
  final serverId = ref.watch(
    apiServiceProvider.select((api) => api?.serverConfig.id),
  );
  final userId = ref.watch(currentUserProvider2.select((user) => user?.id));
  final database = ref.watch(appDatabaseProvider);
  final cache = McpAppResourceCache(
    database: database,
    manager: database == null ? null : ref.read(databaseManagerProvider),
    client: () {
      final api = ref.read(apiServiceProvider);
      // Not another account's, even before this cache is replaced.
      return api?.serverConfig.id == serverId &&
              ref.read(currentUserProvider2)?.id == userId
          ? api
          : null;
    },
  );
  ref.onDispose(cache.dispose);
  return cache;
});

/// The invocation cache, backed by the existing account-private cache table.
/// Account sign-out/removal purges its database through the normal lifecycle.
class McpAppResourceCache {
  McpAppResourceCache({
    AppDatabase? database,
    DatabaseManager? manager,
    ApiService? Function()? client,
  }) : _database = database,
       _manager = manager,
       _client = client {
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
  static const _maxFailures = 256;
  final AppDatabase? _database;
  final DatabaseManager? _manager;
  final ApiService? Function()? _client;
  final _entries = <String, McpAppCacheEntry>{};
  final _sizes = <String, int>{};
  final _heightWrites = <String, Map<String, num>>{};
  final _loads = <String, Future<McpAppCacheEntry>>{};
  final _failures = <String, Object>{};
  final _tokens = <CancelToken>{};
  int _bytes = 0;
  int _lastUsed = 0;
  bool _disposed = false;
  Future<void> _pending = Future<void>.value();
  late final Future<void> ready;

  Future<void> get settled => _pending;
  McpAppCacheEntry? operator [](String? key) => _entries[key];

  /// The account's client for a new request, which a token refresh
  /// replaces; null once this cache is closed or the account has none.
  ApiService? get client => _disposed ? null : _client?.call();

  Future<McpAppCacheEntry?> read(String? key) async {
    await ready;
    return _use(key);
  }

  /// [key]'s entry: the cached one, the request already on its way for it,
  /// or a new one through [fetch], stored at [height].
  ///
  /// [fetch] gets the [client] there is when the request starts, which may
  /// be after a wait for the disk. When a token refresh replaces that client
  /// before it answers, the request is made again through the new one.
  ///
  /// The request finishes into the cache even when its caller has gone, so
  /// a row scrolled away mid-load does not ask again when it comes back;
  /// only [dispose] cancels it. A failure is remembered until [remove], so a
  /// failed app is not asked for again each time its row mounts. Without a
  /// [key] nothing is shared or kept, and the request is its caller's alone:
  /// [cancelToken] stops it.
  Future<McpAppCacheEntry> load(
    String? key, {
    required double height,
    required McpAppResourceFetch fetch,
    CancelToken? cancelToken,
  }) async {
    if (key == null) {
      return (resource: await _fetch(fetch, cancelToken), height: height);
    }
    await ready;
    if (_use(key) case final entry?) return entry;
    if (_failures[key] case final failure?) throw failure;
    return _loads[key] ??= _fetchInto(key, height, fetch);
  }

  Future<McpAppCacheEntry> _fetchInto(
    String key,
    double height,
    McpAppResourceFetch fetch,
  ) async {
    try {
      final entry = (resource: await _fetch(fetch), height: height);
      put(key, entry);
      return entry;
    } catch (error) {
      // Without a client the failure is not the app's.
      if (client != null) {
        _failures[key] = error;
        if (_failures.length > _maxFailures) {
          _failures.remove(_failures.keys.first);
        }
      }
      rethrow;
    } finally {
      _loads.remove(key);
    }
  }

  Future<OpenWebUiMcpAppResource> _fetch(
    McpAppResourceFetch fetch, [
    CancelToken? cancelToken,
  ]) async {
    final token = cancelToken ?? CancelToken();
    _tokens.add(token);
    try {
      while (true) {
        final current = client;
        if (current == null) {
          throw StateError('No client serves the MCP App cache.');
        }
        try {
          return await fetch(current, token);
        } catch (_) {
          if (token.isCancelled || identical(client, current)) rethrow;
        }
      }
    } finally {
      _tokens.remove(token);
    }
  }

  McpAppCacheEntry? _use(String? key) {
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

  /// Forgets [key]'s entry and its failure, so the next [load] asks again.
  void remove(String? key) {
    if (_disposed || key == null) return;
    _failures.remove(key);
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
    for (final token in _tokens) {
      token.cancel('closed');
    }
    _tokens.clear();
    _loads.clear();
    _failures.clear();
    _entries.clear();
    _sizes.clear();
    _bytes = 0;
    _heightWrites.clear();
  }
}
