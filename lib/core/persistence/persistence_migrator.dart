import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../utils/debug_logger.dart';
import 'conversation_store.dart';
import 'database/app_database.dart';
import 'hive_boxes.dart';
import 'persistence_keys.dart';

/// Handles one-time persistence migrations.
///
/// Versions:
///   1 — SharedPreferences → Hive boxes (Phase 1).
///   2 — Per-conversation Hive blobs → SQLite rows (Phase 3a).
class PersistenceMigrator {
  PersistenceMigrator({
    required HiveBoxes hiveBoxes,
    required AppDatabase database,
  }) : _boxes = hiveBoxes,
       _database = database;

  static const int _targetVersion = 2;
  static bool _migrationComplete = false;

  /// Resets the process-wide "already migrated" flag. Tests only.
  @visibleForTesting
  static void resetForTests() {
    _migrationComplete = false;
  }

  final HiveBoxes _boxes;
  final AppDatabase _database;

  Future<void> migrateIfNeeded() async {
    // Fast path: if we already checked migration in this app session, skip
    if (_migrationComplete) {
      return;
    }

    final currentVersion =
        (_boxes.metadata.get(HiveStoreKeys.migrationVersion) as int?) ?? 0;
    if (currentVersion >= _targetVersion) {
      _migrationComplete = true;
      return;
    }

    DebugLogger.log(
      'Starting persistence migration: v$currentVersion → v$_targetVersion',
      scope: 'persistence/migration',
    );

    try {
      if (currentVersion < 1) {
        final prefs = await SharedPreferences.getInstance();
        await _migratePreferences(prefs);
        await _migrateCaches(prefs);
        await _migrateAttachmentQueue(prefs);
        await _migrateTaskQueue(prefs);
        await _boxes.metadata.put(HiveStoreKeys.migrationVersion, 1);
        await _cleanupLegacyKeys(prefs);
      }

      if (currentVersion < 2) {
        await _migrateConversationsToSqlite();
        await _boxes.metadata.put(HiveStoreKeys.migrationVersion, 2);
      }

      _migrationComplete = true;
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

  /// Move every cached conversation from Hive blob storage into the SQLite
  /// `conversations` + `messages` tables. Best-effort per conversation —
  /// one bad blob does not abort the whole migration.
  Future<void> _migrateConversationsToSqlite() async {
    final store = ConversationStore(_database);
    int migrated = 0;
    int skipped = 0;
    final consumedKeys = <dynamic>[];

    final perConversationKeys = _boxes.caches.keys
        .whereType<String>()
        .where((k) => k.startsWith('chat_history_'))
        .toList(growable: false);

    final seen = <String>{};

    for (final key in perConversationKeys) {
      try {
        final stored = _boxes.caches.get(key);
        final json = _decodeStoredConversation(stored);
        if (json == null) {
          skipped++;
          continue;
        }
        final conv = Conversation.fromJson(json);
        await store.upsertConversation(conv);
        consumedKeys.add(key);
        seen.add(conv.id);
        migrated++;
      } catch (error, stack) {
        skipped++;
        DebugLogger.error(
          'Failed to migrate conversation blob $key',
          scope: 'persistence/migration',
          error: error,
          stackTrace: stack,
        );
      }
    }

    // Pick up any conversations that only exist in the legacy list-blob.
    final listBlob = _boxes.caches.get(HiveStoreKeys.localConversations);
    final listEntries = _decodeStoredConversationList(listBlob);
    for (final json in listEntries) {
      try {
        final conv = Conversation.fromJson(json);
        if (seen.contains(conv.id)) continue;
        await store.upsertConversation(conv);
        seen.add(conv.id);
        migrated++;
      } catch (error, stack) {
        skipped++;
        DebugLogger.error(
          'Failed to migrate list-blob conversation',
          scope: 'persistence/migration',
          error: error,
          stackTrace: stack,
        );
      }
    }

    if (consumedKeys.isNotEmpty) {
      await _boxes.caches.deleteAll(consumedKeys);
    }

    DebugLogger.log(
      'Conversation migration: $migrated moved, $skipped skipped',
      scope: 'persistence/migration',
    );
  }

  Map<String, dynamic>? _decodeStoredConversation(Object? stored) {
    if (stored == null) return null;
    if (stored is String && stored.isNotEmpty) {
      final decoded = jsonDecode(stored);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    }
    if (stored is Map<String, dynamic>) return stored;
    if (stored is Map) return Map<String, dynamic>.from(stored);
    return null;
  }

  List<Map<String, dynamic>> _decodeStoredConversationList(Object? stored) {
    if (stored == null) return const [];
    try {
      if (stored is String && stored.isNotEmpty) {
        final decoded = jsonDecode(stored);
        if (decoded is List) {
          return decoded
              .whereType<Object>()
              .map((entry) {
                if (entry is Map<String, dynamic>) return entry;
                if (entry is Map) return Map<String, dynamic>.from(entry);
                return null;
              })
              .whereType<Map<String, dynamic>>()
              .toList(growable: false);
        }
      }
      if (stored is List) {
        return stored
            .whereType<Object>()
            .map((entry) {
              if (entry is Map<String, dynamic>) return entry;
              if (entry is Map) return Map<String, dynamic>.from(entry);
              return null;
            })
            .whereType<Map<String, dynamic>>()
            .toList(growable: false);
      }
    } catch (_) {
      // Ignore — return empty.
    }
    return const [];
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
