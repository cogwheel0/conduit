/// Lightweight in-memory cache with TTL enforcement and LRU eviction.
///
/// Centralizes cache handling so services can avoid duplicating map and
/// timestamp bookkeeping. Entries expire after [defaultTtl] and the cache is
/// trimmed to [maxEntries] using least-recently-used eviction.
class CacheManager {
  CacheManager({
    Duration defaultTtl = const Duration(minutes: 5),
    int maxEntries = 64,
  }) : _defaultTtl = defaultTtl,
       _maxEntries = maxEntries;

  final Duration _defaultTtl;
  final int _maxEntries;
  final Map<String, _CacheRecord> _entries = {};

  /// Reads a cached value and returns whether the lookup was a hit.
  ({bool hit, T? value}) lookup<T>(String key) {
    final record = _getRecord(key);
    if (record == null) return (hit: false, value: null);
    return (hit: true, value: record.value as T?);
  }

  /// Stores [value] with an optional [ttl] override.
  void write<T>(String key, T? value, {Duration? ttl}) {
    final now = DateTime.now();
    _entries[key] = _CacheRecord(
      value: value,
      ttl: ttl ?? _defaultTtl,
      createdAt: now,
      lastAccessed: now,
    );
    _enforceLimits(now);
  }

  /// Removes a single cached entry.
  void invalidate(String key) {
    _entries.remove(key);
  }

  /// Removes entries that match [predicate].
  void invalidateMatching(bool Function(String key) predicate) {
    _entries.removeWhere((key, _) => predicate(key));
  }

  /// Clears all cached entries.
  void clear() {
    _entries.clear();
  }

  /// Current cache statistics for debugging and health checks.
  Map<String, dynamic> stats() {
    final now = DateTime.now();
    return {
      'size': _entries.length,
      'maxEntries': _maxEntries,
      'defaultTtlSeconds': _defaultTtl.inSeconds,
      'entries': _entries.map((key, record) {
        final age = now.difference(record.createdAt);
        final idle = now.difference(record.lastAccessed);
        return MapEntry(key, {
          'ageSeconds': age.inSeconds,
          'idleSeconds': idle.inSeconds,
          'ttlSeconds': record.ttl.inSeconds,
        });
      }),
    };
  }

  _CacheRecord? _getRecord(String key) {
    final record = _entries[key];
    if (record == null) return null;

    final now = DateTime.now();
    if (record.isExpired(now)) {
      _entries.remove(key);
      return null;
    }

    record.touch(now);
    return record;
  }

  void _enforceLimits(DateTime now) {
    _removeExpired(now);
    if (_entries.length <= _maxEntries) return;

    final oldestFirst = _entries.entries.toList()
      ..sort((a, b) => a.value.lastAccessed.compareTo(b.value.lastAccessed));
    final overflow = oldestFirst.length - _maxEntries;
    for (var i = 0; i < overflow; i++) {
      _entries.remove(oldestFirst[i].key);
    }
  }

  void _removeExpired(DateTime now) {
    _entries.removeWhere((_, record) => record.isExpired(now));
  }
}

class _CacheRecord {
  _CacheRecord({
    required this.value,
    required this.ttl,
    required this.createdAt,
    required this.lastAccessed,
  });

  final Object? value;
  final Duration ttl;
  final DateTime createdAt;
  DateTime lastAccessed;

  bool isExpired(DateTime now) {
    return now.difference(createdAt) > ttl;
  }

  void touch(DateTime now) {
    lastAccessed = now;
  }
}
