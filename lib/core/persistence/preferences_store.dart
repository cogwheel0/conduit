import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// Test-only interception point for preference writes.
///
/// Returning null continues to the real platform write. Returning true or
/// false replaces its result, which lets tests pause or fail a specific write
/// without replacing SharedPreferences' transitive platform implementation.
@visibleForTesting
typedef PreferenceWriteInterceptor =
    Future<bool?> Function(
      SharedPreferences preferences,
      String key,
      Object? value,
    );

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
  static PreferenceWriteInterceptor? _debugWriteInterceptor;

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
  @visibleForTesting
  static void debugOverride(
    SharedPreferences prefs, {
    PreferenceWriteInterceptor? writeInterceptor,
  }) {
    _prefs = prefs;
    _debugWriteInterceptor = writeInterceptor;
  }

  @visibleForTesting
  static void debugReset() {
    _prefs = null;
    _debugWriteInterceptor = null;
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
    await _writeValue(key, value);
  }

  /// Persists [value] and throws if the platform reports a failed disk write.
  ///
  /// Use this for security boundaries whose in-memory cache must not be treated
  /// as durable when SharedPreferences returns false (notably trust revocation
  /// and principal rotation). Ordinary UI preferences retain [put]'s legacy
  /// best-effort behavior.
  static Future<void> putChecked(String key, Object? value) async {
    if (_prefs == null) {
      throw StateError(
        'PreferencesStore.ensureInitialized() must be awaited before a checked '
        'preference write.',
      );
    }
    if (!await _writeValue(key, value)) {
      throw StateError('Preference write failed for "$key".');
    }
  }

  /// Persists a security-sensitive value only if [canWrite] still owns the
  /// mutation at the exact synchronous cache-write boundary.
  ///
  /// The optional test interceptor may yield before a real SharedPreferences
  /// call. Checking admission inside [_writeValue], after that yield and
  /// immediately before `set*`/`remove`, prevents a queued stale clear from
  /// deleting a newer fail-closed marker. Returns false when ownership was
  /// lost without touching the preference.
  static Future<bool> putCheckedIf(
    String key,
    Object? value, {
    required bool Function() canWrite,
  }) async {
    if (_prefs == null) {
      throw StateError(
        'PreferencesStore.ensureInitialized() must be awaited before a checked '
        'preference write.',
      );
    }
    var admitted = false;
    final succeeded = await _writeValue(
      key,
      value,
      beforeWrite: () {
        if (!canWrite()) return false;
        admitted = true;
        return true;
      },
    );
    if (!succeeded) {
      throw StateError('Preference write failed for "$key".');
    }
    return admitted;
  }

  static Future<bool> _writeValue(
    String key,
    Object? value, {
    bool Function()? beforeWrite,
  }) async {
    final prefs = _prefs;
    // Ordinary preference writes are best-effort before bootstrap: true means
    // the write was intentionally skipped, not that anything reached disk.
    if (prefs == null) return true;
    final interceptor = _debugWriteInterceptor;
    if (interceptor != null) {
      final intercepted = await interceptor(prefs, key, value);
      if (intercepted != null) {
        if (beforeWrite != null && !beforeWrite()) return true;
        return intercepted;
      }
    }
    if (beforeWrite != null && !beforeWrite()) return true;
    if (value == null) {
      return prefs.remove(key);
    }
    if (value is bool) {
      return prefs.setBool(key, value);
    } else if (value is int) {
      return prefs.setInt(key, value);
    } else if (value is double) {
      return prefs.setDouble(key, value);
    } else if (value is String) {
      return prefs.setString(key, value);
    } else if (value is List<String>) {
      return prefs.setStringList(key, value);
    } else if (value is List) {
      return prefs.setStringList(
        key,
        value.map((e) => e.toString()).toList(growable: false),
      );
    } else {
      return prefs.setString(key, value.toString());
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
