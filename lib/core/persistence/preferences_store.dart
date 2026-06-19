import 'package:shared_preferences/shared_preferences.dart';

/// Synchronous key-value preference store backed by a single preloaded
/// [SharedPreferences] instance.
///
/// This is the seam that replaces the Hive `preferences_v1` box. The whole app
/// reads simple config (theme, locale, settings, drawer/sidebar UI state,
/// feature flags) SYNCHRONOUSLY during provider/widget build, so we deliberately
/// use the **legacy** [SharedPreferences] API: after a single awaited
/// [ensureInitialized] at bootstrap, every getter is synchronous against the
/// in-memory cache and writes update that cache synchronously (the returned
/// Future is just the disk flush).
///
/// Do NOT migrate this to `SharedPreferencesAsync`/`SharedPreferencesWithCache`:
/// those have no synchronous getters and would break theme/locale on cold start.
///
/// Exposed as a static (not a Riverpod provider) because most readers reach it
/// from non-Riverpod code (e.g. `current_localizations.dart`) or static service
/// methods.
class PreferencesStore {
  PreferencesStore._();

  static SharedPreferences? _prefs;

  /// True once [ensureInitialized] has completed and synchronous reads are safe.
  static bool get isReady => _prefs != null;

  /// The preloaded instance. Throws if [ensureInitialized] hasn't run.
  static SharedPreferences get instance {
    final prefs = _prefs;
    if (prefs == null) {
      throw StateError(
        'PreferencesStore.ensureInitialized() must be awaited at bootstrap '
        'before any synchronous preference read.',
      );
    }
    return prefs;
  }

  /// Preloads the shared instance. Safe to call multiple times.
  static Future<SharedPreferences> ensureInitialized() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  /// Test seam: inject a (mock) instance. Pair with
  /// `SharedPreferences.setMockInitialValues({...})`.
  static void debugOverride(SharedPreferences prefs) {
    _prefs = prefs;
  }

  static void debugReset() {
    _prefs = null;
  }

  // --- reads (synchronous) -------------------------------------------------

  /// Hive-box-like dynamic read. Returns null when not ready or absent.
  static Object? getRaw(String key) => _prefs?.get(key);

  /// Typed read that returns null on absence or type mismatch (mirrors the old
  /// `_getPreference<T>` Hive helper).
  static T? get<T>(String key) {
    final value = _prefs?.get(key);
    return value is T ? value : null;
  }

  static bool? getBool(String key) => _prefs?.getBool(key);
  static int? getInt(String key) => _prefs?.getInt(key);
  static double? getDouble(String key) => _prefs?.getDouble(key);
  static String? getString(String key) => _prefs?.getString(key);
  static List<String>? getStringList(String key) => _prefs?.getStringList(key);
  static bool containsKey(String key) => _prefs?.containsKey(key) ?? false;

  // --- writes --------------------------------------------------------------

  /// Hive-box-like write that dispatches by runtime type. A null value removes
  /// the key. Lists are coerced to `List<String>` (the only list type
  /// shared_preferences supports).
  static Future<void> put(String key, Object? value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    if (value == null) {
      await prefs.remove(key);
      return;
    }
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    } else if (value is List<String>) {
      await prefs.setStringList(key, value);
    } else if (value is List) {
      await prefs.setStringList(
        key,
        value.map((e) => e.toString()).toList(growable: false),
      );
    } else {
      await prefs.setString(key, value.toString());
    }
  }

  static Future<void> putAll(Map<String, Object?> entries) async {
    for (final entry in entries.entries) {
      await put(entry.key, entry.value);
    }
  }

  static Future<void> remove(String key) async {
    await _prefs?.remove(key);
  }

  /// Clears all stored values, optionally preserving [preserve] (e.g. the
  /// migration gate so a wipe doesn't trigger a re-migration of stale Hive
  /// data). Snapshots preserved values, clears, then restores them.
  static Future<void> clear({Set<String> preserve = const {}}) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final saved = <String, Object?>{
      for (final key in preserve)
        if (prefs.containsKey(key)) key: prefs.get(key),
    };
    await prefs.clear();
    for (final entry in saved.entries) {
      await put(entry.key, entry.value);
    }
  }
}
