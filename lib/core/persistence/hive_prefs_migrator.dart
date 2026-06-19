import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/debug_logger.dart';
import 'hive_boxes.dart';
import 'persistence_keys.dart';
import 'preferences_store.dart';

/// One-time migration of the Hive `preferences_v1` box (and the server-scoped
/// `local_transport_options` cache slot) into shared_preferences — PR-1 of the
/// Hive removal.
///
/// Idempotent and crash-safe: values are copied with OVERWRITE semantics and the
/// gate flag ([PreferenceKeys.hiveToPrefsMigrationV1]) is set LAST, so a crash
/// mid-copy simply re-runs and overwrites on the next launch. The Hive boxes are
/// left intact (read-only) — they're dropped in a later PR once everyone has
/// migrated.
///
/// Must run AFTER both Hive boxes are open AND
/// [PreferencesStore.ensureInitialized] has completed, and BEFORE any provider
/// reads a preference.
class HivePrefsMigrator {
  HivePrefsMigrator({required HiveBoxes hiveBoxes}) : _boxes = hiveBoxes;

  final HiveBoxes _boxes;

  static bool _done = false;

  @visibleForTesting
  static void debugReset() {
    _done = false;
  }

  Future<void> migrateIfNeeded() async {
    if (_done) return;
    if (PreferencesStore.getBool(PreferenceKeys.hiveToPrefsMigrationV1) ==
        true) {
      _done = true;
      return;
    }

    try {
      await _copyPreferences();
      await _copyTransportOptions();
      // Flag last: the gate is only set once every value has been copied.
      await PreferencesStore.put(PreferenceKeys.hiveToPrefsMigrationV1, true);
      _done = true;
      DebugLogger.log(
        'Hive preferences → shared_preferences migration completed',
        scope: 'persistence/migration',
      );
    } catch (error, stack) {
      DebugLogger.error(
        'Hive → shared_preferences migration failed',
        scope: 'persistence/migration',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> _copyPreferences() async {
    final box = _boxes.preferences;
    for (final rawKey in box.keys) {
      final key = rawKey.toString();
      final value = box.get(rawKey);
      if (value == null) continue;
      // `serverFeatureAvailability` was a nested Map in Hive; the new
      // shared_preferences reader expects a JSON string. Everything else is a
      // primitive or string list that `PreferencesStore.put` handles directly.
      if (value is Map) {
        await PreferencesStore.put(key, jsonEncode(value));
      } else {
        await PreferencesStore.put(key, value);
      }
    }
  }

  Future<void> _copyTransportOptions() async {
    final stored = _boxes.caches.get(HiveStoreKeys.localTransportOptions);
    if (stored is! Map) return;
    final serverId = stored['serverId'];
    final data = stored['data'];
    if (serverId is! String || serverId.isEmpty || data is! Map) return;
    // Mirror OptimizedStorageService._transportOptionsKey.
    final key =
        '${PreferenceKeys.transportOptionsPrefix}:'
        '${base64Url.encode(utf8.encode(serverId))}';
    await PreferencesStore.put(key, jsonEncode(Map<String, dynamic>.from(data)));
  }
}
