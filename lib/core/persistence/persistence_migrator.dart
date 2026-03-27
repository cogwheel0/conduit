import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/debug_logger.dart';
import 'hive_boxes.dart';
import 'persistence_keys.dart';

/// Handles one-time migration from SharedPreferences to Hive-backed storage.
class PersistenceMigrator {
  PersistenceMigrator({required HiveBoxes hiveBoxes}) : _boxes = hiveBoxes;

  static const int _targetVersion = 1;
  static bool _migrationComplete = false;

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
      await _migratePreferences(prefs);
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

  Future<void> _migratePreferences(SharedPreferences prefs) async {
    final updates = <String, Object?>{};

    void copyBool(String key) {
      final value = prefs.getBool(key);
      if (value != null) updates[key] = value;
    }

    void copyDouble(String key) {
      final value = prefs.getDouble(key);
      if (value != null) updates[key] = value;
    }

    void copyString(String key) {
      final value = prefs.getString(key);
      if (value != null && value.isNotEmpty) updates[key] = value;
    }

    void copyStringList(String key) {
      final value = prefs.getStringList(key);
      if (value != null && value.isNotEmpty) {
        updates[key] = List<String>.from(value);
      }
    }

    copyBool(PreferenceKeys.reduceMotion);
    copyDouble(PreferenceKeys.animationSpeed);
    copyBool(PreferenceKeys.hapticFeedback);
    copyBool(PreferenceKeys.disableHapticsWhileStreaming);
    copyBool(PreferenceKeys.highContrast);
    copyBool(PreferenceKeys.largeText);
    copyBool(PreferenceKeys.darkMode);
    copyString(PreferenceKeys.defaultModel);
    copyString(PreferenceKeys.voiceLocaleId);
    copyBool(PreferenceKeys.voiceHoldToTalk);
    copyBool(PreferenceKeys.voiceAutoSendFinal);
    copyString(PreferenceKeys.voiceSttPreference);
    copyString(PreferenceKeys.socketTransportMode);
    copyStringList(PreferenceKeys.quickPills);
    copyBool(PreferenceKeys.sendOnEnterKey);
    copyString(PreferenceKeys.activeServerId);
    copyString(PreferenceKeys.themeMode);
    copyString(PreferenceKeys.themePalette);
    copyString(PreferenceKeys.localeCode);
    copyBool(PreferenceKeys.reviewerMode);

    if (updates.isNotEmpty) {
      await _boxes.preferences.putAll(updates);
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
    final keysToRemove = <String>[
      PreferenceKeys.reduceMotion,
      PreferenceKeys.animationSpeed,
      PreferenceKeys.hapticFeedback,
      PreferenceKeys.disableHapticsWhileStreaming,
      PreferenceKeys.highContrast,
      PreferenceKeys.largeText,
      PreferenceKeys.darkMode,
      PreferenceKeys.defaultModel,
      PreferenceKeys.voiceLocaleId,
      PreferenceKeys.voiceHoldToTalk,
      PreferenceKeys.voiceAutoSendFinal,
      PreferenceKeys.voiceSttPreference,
      PreferenceKeys.socketTransportMode,
      PreferenceKeys.quickPills,
      PreferenceKeys.sendOnEnterKey,
      PreferenceKeys.activeServerId,
      PreferenceKeys.themeMode,
      PreferenceKeys.themePalette,
      PreferenceKeys.localeCode,
      PreferenceKeys.reviewerMode,
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
