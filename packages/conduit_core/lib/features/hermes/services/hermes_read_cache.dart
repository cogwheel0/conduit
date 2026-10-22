import '../../../services/cache_manager.dart';

/// Short-lived, memory-only reads owned by one Hermes connection service.
/// CacheManager supplies TTL/LRU; this layer only coalesces pending reads and
/// prevents an invalidated request from repopulating the cache when it ends.
class HermesReadCache {
  final _values = CacheManager(
    defaultTtl: const Duration(seconds: 30),
    maxEntries: 32,
  );
  final _pending = <String, Future<Object?>>{};

  T? cached<T>(String key) => _values.lookup<T>(key).value;

  Future<T> read<T>(
    String key,
    Future<T> Function() load, {
    bool refresh = false,
    Duration? ttl,
  }) async {
    if (refresh) invalidate(key);
    final cached = _values.lookup<T>(key);
    if (cached.hit) return cached.value as T;
    final existing = _pending[key];
    if (existing != null) return await existing as T;
    final request = Future<T>.sync(load);
    _pending[key] = request;
    try {
      final value = await request;
      if (identical(_pending[key], request)) {
        _values.write(key, value, ttl: ttl);
      }
      return value;
    } finally {
      if (identical(_pending[key], request)) _pending.remove(key);
    }
  }

  void invalidate([String? prefix]) {
    if (prefix == null) {
      _values.clear();
      _pending.clear();
    } else {
      _values.invalidateMatching((key) => key.startsWith(prefix));
      _pending.removeWhere((key, _) => key.startsWith(prefix));
    }
  }
}
