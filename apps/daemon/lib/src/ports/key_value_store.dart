import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/ports/key_value_store.dart';

/// The desktop [KeyValueStore]: one JSON file under `userData`.
///
/// The interface requires *synchronous* reads, because the core reads
/// preferences while building providers on a cold start. So the file is
/// parsed once at [open] and the in-memory map is the source of truth from
/// then on; writes update it immediately and reach disk soon after.
///
/// Nothing credential-shaped belongs here -- that is [DaemonSecureStore] --
/// so this file is plain JSON, readable by anyone debugging a support ticket.
final class DaemonKeyValueStore implements KeyValueStore {
  DaemonKeyValueStore._(this._file, this._values);

  /// Opens, or starts empty if [file] does not exist.
  ///
  /// Unlike the secure store, an unreadable file here is *not* fatal: these
  /// are preferences, and losing "which theme was selected" to start the app
  /// is better than refusing to start at all. The damaged file is kept
  /// alongside as `.corrupt` rather than overwritten, so it can still be
  /// looked at.
  static Future<DaemonKeyValueStore> open(File file) async {
    var values = <String, Object?>{};
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) values = Map<String, Object?>.from(decoded);
      } on FormatException {
        await file.rename('${file.path}.corrupt');
      }
    }
    return DaemonKeyValueStore._(file, values);
  }

  final File _file;
  final Map<String, Object?> _values;

  Future<void> _pending = Future<void>.value();

  @override
  Object? get(String key) => _values[key];

  /// `as T?` would throw on a mismatch; the contract is "absent or wrong type
  /// reads as null", so that a preference written by an older build with a
  /// different type cannot crash the reader.
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

  /// JSON has no typed arrays, so a decoded list arrives as `List<dynamic>`
  /// however it was written. Rebuild it, and reject one holding non-strings
  /// rather than throwing on first use.
  @override
  List<String>? getStringList(String key) {
    final value = _values[key];
    if (value is! List) return null;
    if (value.any((element) => element is! String)) return null;
    return value.cast<String>().toList();
  }

  @override
  bool containsKey(String key) => _values.containsKey(key);

  @override
  Set<String> get keys => _values.keys.toSet();

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
  Future<bool> remove(String key) {
    _values.remove(key);
    return _flushSoon();
  }

  @override
  Future<bool> clear() {
    _values.clear();
    return _flushSoon();
  }

  Future<bool> _set(String key, Object? value) {
    _values[key] = value;
    return _flushSoon();
  }

  /// Returns whether the value reached disk, which the interface says callers
  /// may act on -- the incomplete-logout fence does.
  Future<bool> _flushSoon() {
    final flushed = _pending.then((_) => _flush());
    _pending = flushed.then((_) {}, onError: (_) {});
    return flushed;
  }

  Future<bool> _flush() async {
    try {
      final directory = _file.parent;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(jsonEncode(_values), flush: true);
      await temporary.rename(_file.path);
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
