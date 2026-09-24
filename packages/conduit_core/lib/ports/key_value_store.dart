/// Plain, non-secret key/value storage.
///
/// Theme, locale, feature flags and UI state live here — everything the app
/// reads *synchronously* while building providers and widgets on a cold
/// start. That constraint drives the whole shape: reads return a value, not a
/// future, which means an implementation must load its contents fully before
/// the app is allowed to read.
///
/// Writes are asynchronous because only the disk flush is; a conforming
/// implementation updates its in-memory view synchronously so the next read
/// already sees the new value.
///
/// Anything credential-shaped belongs in `SecureKeyValueStore` instead.
abstract interface class KeyValueStore {
  /// Untyped read. Null when absent.
  Object? get(String key);

  /// Typed reads. Null on absence *or* type mismatch — a preference written
  /// by an older build with a different type must not crash the reader.
  bool? getBool(String key);
  int? getInt(String key);
  double? getDouble(String key);
  String? getString(String key);
  List<String>? getStringList(String key);

  bool containsKey(String key);

  /// Every key currently stored. Used by migrations and by "export
  /// diagnostics", never on a hot path.
  Set<String> get keys;

  /// Each returns whether the value reached the backing store.
  ///
  /// False is not an error to swallow: the caller decides whether a failed
  /// preference write is worth surfacing, and some (the incomplete-logout
  /// fence) very much are.
  Future<bool> setBool(String key, bool value);
  Future<bool> setInt(String key, int value);
  Future<bool> setDouble(String key, double value);
  Future<bool> setString(String key, String value);
  Future<bool> setStringList(String key, List<String> value);

  Future<bool> remove(String key);

  /// Removes everything. Callers that need to keep a key snapshot it first.
  Future<bool> clear();
}

/// A fully in-memory [KeyValueStore].
///
/// The natural default for tests, and a correct implementation for a host
/// with no persistence — settings simply do not survive a restart.
class InMemoryKeyValueStore implements KeyValueStore {
  InMemoryKeyValueStore([Map<String, Object?>? seed])
    : _values = <String, Object?>{...?seed};

  final Map<String, Object?> _values;

  @override
  Object? get(String key) => _values[key];

  /// `as T?` would throw on a mismatch; this returns null instead, matching
  /// the contract's "absent or wrong type" rule.
  T? _typed<T>(String key) {
    final value = _values[key];
    return value is T ? value : null;
  }

  @override
  bool? getBool(String key) => _typed<bool>(key);

  @override
  int? getInt(String key) => _typed<int>(key);

  @override
  double? getDouble(String key) => _typed<double>(key);

  @override
  String? getString(String key) => _typed<String>(key);

  @override
  List<String>? getStringList(String key) => _typed<List<String>>(key);

  @override
  bool containsKey(String key) => _values.containsKey(key);

  @override
  Set<String> get keys => _values.keys.toSet();

  Future<bool> _set(String key, Object? value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) => _set(key, value);

  @override
  Future<bool> setInt(String key, int value) => _set(key, value);

  @override
  Future<bool> setDouble(String key, double value) => _set(key, value);

  @override
  Future<bool> setString(String key, String value) => _set(key, value);

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _set(key, List<String>.from(value));

  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    _values.clear();
    return true;
  }
}
