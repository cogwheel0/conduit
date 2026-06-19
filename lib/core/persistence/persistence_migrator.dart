import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/debug_logger.dart';
import 'hive_boxes.dart';
import 'persistence_keys.dart';

/// Handles one-time migration from SharedPreferences to Hive-backed storage.
class PersistenceMigrator {
  PersistenceMigrator({required HiveBoxes hiveBoxes}) : _boxes = hiveBoxes;

  static const int _targetVersion = 1;
  static bool _migrationComplete = false;

  @visibleForTesting
  static void debugResetMigrationComplete() {
    _migrationComplete = false;
  }

  final HiveBoxes _boxes;

  Future<void> migrateIfNeeded() async {
    // Fast path: if we already checked migration in this app session, skip
    if (_migrationComplete) {
      return;
    }

    final currentVersion =
        _boxes.metadata.get(HiveStoreKeys.migrationVersion) as int?;
    if (currentVersion != null && currentVersion >= _targetVersion) {
      _migrationComplete = true;
      return;
    }

    DebugLogger.log(
      'Starting SharedPreferences → Hive migration',
      scope: 'persistence/migration',
    );

    try {
      final prefs = await SharedPreferences.getInstance();
      // NOTE: simple preferences are NO LONGER migrated SharedPreferences →
      // Hive. As of the Hive-removal work, shared_preferences is the live store
      // for preferences again, so a pre-Hive install's prefs already sit where
      // they belong; HivePrefsMigrator only copies Hive-resident prefs forward.
      // Only the caches / attachment / task-queue (still Hive-backed) migrate
      // here.
      await _migrateCaches(prefs);
      await _migrateAttachmentQueue(prefs);
      await _migrateTaskQueue(prefs);

      await _boxes.metadata.put(HiveStoreKeys.migrationVersion, _targetVersion);
      _migrationComplete = true;

      await _cleanupLegacyKeys(prefs);
      DebugLogger.log('Migration completed', scope: 'persistence/migration');
    } catch (error, stack) {
      DebugLogger.error(
        'Migration failed',
        scope: 'persistence/migration',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> _migrateCaches(SharedPreferences prefs) async {
    await _migrateJsonListCache(
      prefs,
      HiveStoreKeys.localConversations,
      logLabel: 'local conversations',
    );
    await _migrateJsonListCache(
      prefs,
      HiveStoreKeys.localFolders,
      logLabel: 'local folders',
    );
  }

  Future<void> _migrateJsonListCache(
    SharedPreferences prefs,
    String key, {
    required String logLabel,
  }) async {
    final jsonString = prefs.getString(key);
    if (jsonString == null || jsonString.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        final list = decoded
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList(growable: false);
        await _boxes.caches.put(key, list);
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to migrate $logLabel',
        scope: 'persistence/migration',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> _migrateAttachmentQueue(SharedPreferences prefs) async {
    final jsonString = prefs.getString(
      LegacyPreferenceKeys.attachmentUploadQueue,
    );
    if (jsonString == null || jsonString.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        final list = decoded
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList(growable: false);
        await _boxes.attachmentQueue.put(
          HiveStoreKeys.attachmentQueueEntries,
          list,
        );
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to migrate attachment queue',
        scope: 'persistence/migration',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> _migrateTaskQueue(SharedPreferences prefs) async {
    final jsonString = prefs.getString(LegacyPreferenceKeys.taskQueue);
    if (jsonString == null || jsonString.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is List) {
        final list = decoded
            .map((entry) => Map<String, dynamic>.from(entry as Map))
            .toList(growable: false);
        await _boxes.caches.put(HiveStoreKeys.taskQueue, list);
      }
    } catch (error, stack) {
      DebugLogger.error(
        'Failed to migrate outbound task queue',
        scope: 'persistence/migration',
        error: error,
        stackTrace: stack,
      );
    }
  }

  Future<void> _cleanupLegacyKeys(SharedPreferences prefs) async {
    // Only the caches / queue keys that were copied INTO Hive are removed here.
    // Preference keys are intentionally NOT removed — shared_preferences is the
    // live store for preferences again (see migrateIfNeeded), so deleting them
    // would lose a pre-Hive install's settings. `large_text` is a dead key.
    final keysToRemove = <String>[
      'large_text',
      HiveStoreKeys.localConversations,
      HiveStoreKeys.localFolders,
      HiveStoreKeys.attachmentQueueEntries,
      LegacyPreferenceKeys.attachmentUploadQueue,
      LegacyPreferenceKeys.taskQueue,
    ];

    for (final key in keysToRemove) {
      await prefs.remove(key);
    }
  }
}
