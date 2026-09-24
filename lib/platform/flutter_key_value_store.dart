import 'package:conduit_core/conduit_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Flutter app's [KeyValueStore].
///
/// Wraps the **legacy** `SharedPreferences` API deliberately. The app reads
/// theme, locale and UI state synchronously while building providers on a
/// cold start, and `SharedPreferencesAsync`/`WithCache` have no synchronous
/// getters — switching to them would make the first frame render with the
/// wrong theme. [load] does the one awaited preload that makes those
/// synchronous reads safe.
class FlutterKeyValueStore implements KeyValueStore {
  const FlutterKeyValueStore(this._prefs);

  final SharedPreferences _prefs;

  /// Preloads the platform store. Awaited once, at bootstrap.
  static Future<FlutterKeyValueStore> load() async =>
      FlutterKeyValueStore(await SharedPreferences.getInstance());

  @override
  Object? get(String key) => _prefs.get(key);

  @override
  bool? getBool(String key) => _read(key, _prefs.getBool);

  @override
  int? getInt(String key) => _read(key, _prefs.getInt);

  @override
  double? getDouble(String key) => _read(key, _prefs.getDouble);

  @override
  String? getString(String key) => _read(key, _prefs.getString);

  @override
  List<String>? getStringList(String key) => _read(key, _prefs.getStringList);

  /// `SharedPreferences` throws when a key holds a different type than the
  /// getter expects. The port promises null instead, because a value written
  /// by an older build must not crash the reader.
  T? _read<T>(String key, T? Function(String key) getter) {
    try {
      return getter(key);
    } on TypeError {
      return null;
    }
  }

  @override
  bool containsKey(String key) => _prefs.containsKey(key);

  @override
  Set<String> get keys => _prefs.getKeys();

  @override
  Future<bool> setBool(String key, bool value) => _prefs.setBool(key, value);

  @override
  Future<bool> setInt(String key, int value) => _prefs.setInt(key, value);

  @override
  Future<bool> setDouble(String key, double value) =>
      _prefs.setDouble(key, value);

  @override
  Future<bool> setString(String key, String value) =>
      _prefs.setString(key, value);

  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);

  @override
  Future<bool> remove(String key) => _prefs.remove(key);

  @override
  Future<bool> clear() => _prefs.clear();
}
