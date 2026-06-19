import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/hive_prefs_migrator.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Box<dynamic> preferences;
  late Box<dynamic> caches;
  late Box<dynamic> attachmentQueue;
  late Box<dynamic> metadata;

  HiveBoxes boxes() => HiveBoxes(
    preferences: preferences,
    caches: caches,
    attachmentQueue: attachmentQueue,
    metadata: metadata,
  );

  Future<void> migrate() => HivePrefsMigrator(hiveBoxes: boxes()).migrateIfNeeded();

  String transportKey(String serverId) =>
      '${PreferenceKeys.transportOptionsPrefix}:'
      '${base64Url.encode(utf8.encode(serverId))}';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    HivePrefsMigrator.debugReset();
    tempDir = await Directory.systemTemp.createTemp('hive-prefs-migrator-test');
    Hive.init(tempDir.path);
    preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    attachmentQueue = await Hive.openBox<dynamic>(HiveBoxNames.attachmentQueue);
    metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);
  });

  tearDown(() async {
    PreferencesStore.debugReset();
    HivePrefsMigrator.debugReset();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('copies Hive preference values into shared_preferences', () async {
    await preferences.putAll(<String, Object?>{
      PreferenceKeys.darkMode: false,
      PreferenceKeys.animationSpeed: 0.75,
      PreferenceKeys.defaultModel: 'gpt-4.1',
      PreferenceKeys.quickPills: ['web', 'image'],
      PreferenceKeys.voiceSilenceDuration: 1500,
      // Native Android assistant reads `flutter.android_assistant_trigger`.
      PreferenceKeys.androidAssistantTrigger: 'new_chat',
      // Stored as a nested Map in Hive; becomes a JSON string in prefs.
      PreferenceKeys.serverFeatureAvailability: {
        'server-1::user-1': {'notes': false},
      },
    });

    await migrate();

    check(PreferencesStore.getBool(PreferenceKeys.darkMode)).equals(false);
    check(
      PreferencesStore.getDouble(PreferenceKeys.animationSpeed),
    ).equals(0.75);
    check(
      PreferencesStore.getString(PreferenceKeys.defaultModel),
    ).equals('gpt-4.1');
    check(
      PreferencesStore.getStringList(PreferenceKeys.quickPills)!,
    ).deepEquals(['web', 'image']);
    check(
      PreferencesStore.getInt(PreferenceKeys.voiceSilenceDuration),
    ).equals(1500);
    check(
      PreferencesStore.getString(PreferenceKeys.androidAssistantTrigger),
    ).equals('new_chat');

    final flagsJson = PreferencesStore.getString(
      PreferenceKeys.serverFeatureAvailability,
    );
    check(flagsJson).isNotNull();
    check(jsonDecode(flagsJson!) as Map).deepEquals({
      'server-1::user-1': {'notes': false},
    });

    // Gate set.
    check(
      PreferencesStore.getBool(PreferenceKeys.hiveToPrefsMigrationV1),
    ).equals(true);
  });

  test('copies the server-scoped transport options cache slot', () async {
    await caches.put(HiveStoreKeys.localTransportOptions, {
      'data': {'allowPolling': false, 'allowWebsocketOnly': true},
      'serverId': 'server-a',
    });

    await migrate();

    final raw = PreferencesStore.getString(transportKey('server-a'));
    check(raw).isNotNull();
    check(jsonDecode(raw!) as Map).deepEquals({
      'allowPolling': false,
      'allowWebsocketOnly': true,
    });
  });

  test('is gated: a second run does not overwrite changed prefs', () async {
    await preferences.put(PreferenceKeys.darkMode, false);
    await migrate();
    check(PreferencesStore.getBool(PreferenceKeys.darkMode)).equals(false);

    // User flips the setting after migration; a second migrate must NOT clobber
    // it from the (now stale) Hive value.
    await PreferencesStore.put(PreferenceKeys.darkMode, true);
    HivePrefsMigrator.debugReset(); // simulate a fresh app session
    await migrate();

    check(PreferencesStore.getBool(PreferenceKeys.darkMode)).equals(true);
  });

  test('empty Hive still sets the gate', () async {
    await migrate();
    check(
      PreferencesStore.getBool(PreferenceKeys.hiveToPrefsMigrationV1),
    ).equals(true);
  });
}
