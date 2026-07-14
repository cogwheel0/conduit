import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/socket_transport_availability.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  final secureStorageValues = <String, String>{};
  final secureStorageReadCounts = <String, int>{};
  final secureStorageReadErrors = <String, Object>{};

  late Directory tempDir;
  late Box<dynamic> preferences;
  late Box<dynamic> caches;
  late Box<dynamic> attachmentQueue;
  late Box<dynamic> metadata;
  late WorkerManager workerManager;
  late OptimizedStorageService storage;

  Future<void> saveServerConfigs(Iterable<String> ids) {
    return storage.saveServerConfigs(
      ids.map(_serverConfig).toList(growable: false),
    );
  }

  Future<void> seedLegacyJsonCache(String key, Object payload) {
    return caches.put(key, jsonEncode(payload));
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (methodCall) async {
          final arguments =
              (methodCall.arguments as Map<Object?, Object?>?) ?? const {};
          final key = arguments['key']?.toString();
          switch (methodCall.method) {
            case 'write':
              if (key != null) {
                final value = arguments['value'];
                secureStorageValues[key] = value?.toString() ?? '';
              }
              return null;
            case 'read':
              if (key == null) return null;
              secureStorageReadCounts.update(
                key,
                (count) => count + 1,
                ifAbsent: () => 1,
              );
              final readError = secureStorageReadErrors[key];
              if (readError != null) {
                throw readError;
              }
              return secureStorageValues[key];
            case 'delete':
              if (key != null) {
                secureStorageValues.remove(key);
              }
              return null;
            case 'deleteAll':
              secureStorageValues.clear();
              return null;
            case 'containsKey':
              if (key == null) return false;
              return secureStorageValues.containsKey(key);
            case 'readAll':
              return Map<String, String>.from(secureStorageValues);
            default:
              return null;
          }
        });
    secureStorageValues.clear();
    secureStorageReadCounts.clear();
    secureStorageReadErrors.clear();
    SharedPreferences.setMockInitialValues({});
    PreferencesStore.debugReset();
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    tempDir = await Directory.systemTemp.createTemp(
      'optimized-storage-service-test',
    );
    Hive.init(tempDir.path);
    preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    attachmentQueue = await Hive.openBox<dynamic>(HiveBoxNames.attachmentQueue);
    metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);
    workerManager = WorkerManager(maxConcurrentTasks: 1);
    storage = OptimizedStorageService(
      secureStorage: const FlutterSecureStorage(),
      boxes: HiveBoxes(
        preferences: preferences,
        caches: caches,
        attachmentQueue: attachmentQueue,
        metadata: metadata,
      ),
      workerManager: workerManager,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
    workerManager.dispose();
    PreferencesStore.debugReset();
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'validated active server id reuses cached server configs across repeated lookups',
    () async {
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('server-a');

      expect(await storage.getActiveServerId(), 'server-a');
      expect(await storage.getActiveServerId(), 'server-a');
      expect(await storage.getActiveServerId(), 'server-a');

      expect(secureStorageReadCounts['server_configs_v2'] ?? 0, 0);
    },
  );

  test('server config read failures are not cached as an empty list', () async {
    await saveServerConfigs(['server-a']);
    storage = OptimizedStorageService(
      secureStorage: const FlutterSecureStorage(),
      boxes: HiveBoxes(
        preferences: preferences,
        caches: caches,
        attachmentQueue: attachmentQueue,
        metadata: metadata,
      ),
      workerManager: workerManager,
    );

    secureStorageReadErrors['server_configs_v2'] = PlatformException(
      code: 'read-failed',
      message: 'transient secure storage failure',
    );

    expect(await storage.getServerConfigs(), isEmpty);
    expect(secureStorageReadCounts['server_configs_v2'], 1);

    secureStorageReadErrors.remove('server_configs_v2');

    final configs = await storage.getServerConfigs();

    expect(configs.map((config) => config.id), ['server-a']);
    expect(secureStorageReadCounts['server_configs_v2'], 2);
  });

  test(
    'active server id is recomputed when server configs restore a cached selection',
    () async {
      await storage.setActiveServerId('server-a');
      await storage.saveServerConfigs([_serverConfig('server-b')]);

      expect(await storage.getActiveServerId(), isNull);

      await storage.saveServerConfigs([
        _serverConfig('server-a'),
        _serverConfig('server-b'),
      ]);

      expect(await storage.getActiveServerId(), 'server-a');
    },
  );

  test(
    'transport options round-trip through shared_preferences (sync read)',
    () async {
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('server-a');

      await storage.saveLocalTransportOptions(
        const SocketTransportAvailability(
          allowPolling: false,
          allowWebsocketOnly: true,
        ),
      );

      // Stored in shared_preferences (not the Hive caches box).
      expect(caches.containsKey(HiveStoreKeys.localTransportOptions), isFalse);

      final options = storage.getLocalTransportOptionsSync();
      expect(options?.allowPolling, isFalse);
      expect(options?.allowWebsocketOnly, isTrue);

      final asyncOptions = await storage.getLocalTransportOptions();
      expect(asyncOptions?.allowPolling, isFalse);
      expect(asyncOptions?.allowWebsocketOnly, isTrue);
    },
  );

  test(
    'user-scoped auth cleanup preserves token and saved credentials',
    () async {
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('server-a');
      await storage.saveAuthToken('token-a');
      await storage.saveCredentials(
        serverId: 'server-a',
        username: 'user@example.com',
        password: 'password',
      );
      await seedLegacyJsonCache(HiveStoreKeys.localConversations, [
        _conversationJson('cached-chat'),
      ]);

      await storage.clearUserScopedAuthData();

      expect(await storage.getAuthToken(), 'token-a');
      expect(await storage.getSavedCredentials(), isNotNull);
      expect(caches.containsKey(HiveStoreKeys.localConversations), isFalse);
    },
  );

  test('deleteLegacyConversationCaches removes exactly the legacy keys '
      '(CDT-RFC-001 §9.3) and is idempotent', () async {
    await seedLegacyJsonCache(HiveStoreKeys.localConversations, [
      _conversationJson('legacy-chat'),
    ]);
    await seedLegacyJsonCache(HiveStoreKeys.localFolders, [
      {'id': 'legacy-folder', 'name': 'Legacy Folder'},
    ]);
    await seedLegacyJsonCache(HiveStoreKeys.localTools, [
      {'id': 'tool-1'},
    ]);

    await storage.deleteLegacyConversationCaches();

    expect(caches.containsKey(HiveStoreKeys.localConversations), isFalse);
    expect(caches.containsKey(HiveStoreKeys.localFolders), isFalse);
    // Unrelated cache entries stay untouched.
    expect(caches.containsKey(HiveStoreKeys.localTools), isTrue);

    // Idempotent: a second pass is a no-op.
    await storage.deleteLegacyConversationCaches();
    expect(caches.containsKey(HiveStoreKeys.localConversations), isFalse);
    expect(caches.containsKey(HiveStoreKeys.localFolders), isFalse);
  });

  test(
    'transport options are per-server: another server is not read back',
    () async {
      await saveServerConfigs(['server-a', 'server-b']);
      await storage.setActiveServerId('server-a');
      await storage.saveLocalTransportOptions(
        const SocketTransportAvailability(
          allowPolling: false,
          allowWebsocketOnly: true,
        ),
      );

      // Switching to a server with no cached transport options reads nothing
      // (the per-server prefs key isolates each server).
      await storage.setActiveServerId('server-b');
      expect(storage.getLocalTransportOptionsSync(), isNull);

      // Switching back returns the original options.
      await storage.setActiveServerId('server-a');
      final restored = storage.getLocalTransportOptionsSync();
      expect(restored?.allowPolling, isFalse);
      expect(restored?.allowWebsocketOnly, isTrue);
    },
  );

  test(
    'multi-key user operations hold one database ownership snapshot',
    () async {
      final databaseA = AppDatabase(NativeDatabase.memory());
      final databaseB = AppDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await databaseA.close();
        await databaseB.close();
      });
      var resolutions = 0;
      storage = OptimizedStorageService(
        secureStorage: const FlutterSecureStorage(),
        boxes: HiveBoxes(
          preferences: preferences,
          caches: caches,
          attachmentQueue: attachmentQueue,
          metadata: metadata,
        ),
        workerManager: workerManager,
        databaseAccess: () => OptimizedStorageDatabaseHandle(
          database: resolutions++ == 0 ? databaseA : databaseB,
        ),
      );
      const user = User(
        id: 'user-a',
        username: 'alice',
        email: 'alice@example.test',
        role: 'user',
      );

      await databaseA.appCacheDao.setValue(
        HiveStoreKeys.localUser,
        jsonEncode(user.toJson()),
      );
      await databaseA.appCacheDao.setValue(
        HiveStoreKeys.localUserAvatar,
        'avatar-a',
      );
      await databaseB.appCacheDao.setValue(
        HiveStoreKeys.localUserAvatar,
        'avatar-b-must-survive',
      );

      await storage.saveLocalUser(null);

      expect(resolutions, 1);
      expect(
        await databaseA.appCacheDao.getValue(HiveStoreKeys.localUser),
        isNull,
      );
      expect(
        await databaseA.appCacheDao.getValue(HiveStoreKeys.localUserAvatar),
        isNull,
      );
      expect(
        await databaseB.appCacheDao.getValue(HiveStoreKeys.localUserAvatar),
        'avatar-b-must-survive',
      );

      resolutions = 0;
      await storage.saveLocalUserWithAvatar(user, avatarUrl: 'new-avatar-a');
      expect(resolutions, 1);
      expect(
        await databaseA.appCacheDao.getValue(HiveStoreKeys.localUserAvatar),
        'new-avatar-a',
      );

      resolutions = 0;
      final restored = await storage.getLocalUserWithAvatar();
      expect(resolutions, 1);
      expect(restored?.id, user.id);
      expect(restored?.profileImage, 'new-avatar-a');
    },
  );

  test('default model and model list resolve from the same database', () async {
    final databaseA = AppDatabase(NativeDatabase.memory());
    final databaseB = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await databaseA.close();
      await databaseB.close();
    });
    var resolutions = 0;
    storage = OptimizedStorageService(
      secureStorage: const FlutterSecureStorage(),
      boxes: HiveBoxes(
        preferences: preferences,
        caches: caches,
        attachmentQueue: attachmentQueue,
        metadata: metadata,
      ),
      workerManager: workerManager,
      databaseAccess: () => OptimizedStorageDatabaseHandle(
        database: resolutions++ == 0 ? databaseA : databaseB,
      ),
    );
    const modelA = Model(id: 'model-a', name: 'Model A');
    const modelB = Model(id: 'model-b', name: 'Model B');
    await databaseA.appCacheDao.setValue(
      HiveStoreKeys.localDefaultModel,
      jsonEncode(modelA.toJson()),
    );
    await databaseA.appCacheDao.setValue(
      HiveStoreKeys.localModels,
      jsonEncode([modelA.toJson()]),
    );
    await databaseB.appCacheDao.setValue(
      HiveStoreKeys.localModels,
      jsonEncode([modelB.toJson()]),
    );

    final restored = await storage.getLocalDefaultModel();

    expect(resolutions, 1);
    expect(restored?.id, modelA.id);
  });

  test(
    'user cache cleanup cannot retarget transport options after an A to B switch',
    () async {
      final databaseA = AppDatabase(NativeDatabase.memory());
      addTearDown(databaseA.close);
      final releaseStarted = Completer<void>();
      final releaseGate = Completer<void>();
      addTearDown(() {
        if (!releaseGate.isCompleted) releaseGate.complete();
      });
      storage = OptimizedStorageService(
        secureStorage: const FlutterSecureStorage(),
        boxes: HiveBoxes(
          preferences: preferences,
          caches: caches,
          attachmentQueue: attachmentQueue,
          metadata: metadata,
        ),
        workerManager: workerManager,
        databaseAccess: () => OptimizedStorageDatabaseHandle(
          database: databaseA,
          onRelease: () async {
            if (!releaseStarted.isCompleted) releaseStarted.complete();
            await releaseGate.future;
          },
        ),
      );
      const optionsA = SocketTransportAvailability(
        allowPolling: false,
        allowWebsocketOnly: true,
      );
      const optionsB = SocketTransportAvailability(
        allowPolling: true,
        allowWebsocketOnly: false,
      );
      await saveServerConfigs(['server-a', 'server-b']);
      await storage.setActiveServerId('server-a');
      await storage.saveLocalTransportOptions(optionsA);
      await storage.setActiveServerId('server-b');
      await storage.saveLocalTransportOptions(optionsB);
      await storage.setActiveServerId('server-a');

      final cleanup = storage.clearUserScopedAuthData();
      await releaseStarted.future;

      await storage.setActiveServerId('server-b');
      releaseGate.complete();
      await cleanup;

      expect(storage.getLocalTransportOptionsSync(), optionsB);
      await storage.setActiveServerId('server-a');
      expect(storage.getLocalTransportOptionsSync(), isNull);
    },
  );
}

Map<String, dynamic> _conversationJson(String id) {
  final timestamp = DateTime.utc(2026, 1, 1).toIso8601String();
  return {
    'id': id,
    'title': id,
    'createdAt': timestamp,
    'updatedAt': timestamp,
    'messages': const [],
    'metadata': const <String, dynamic>{},
    'pinned': false,
    'archived': false,
    'tags': const <String>[],
  };
}

ServerConfig _serverConfig(String id) {
  return ServerConfig(id: id, name: id, url: 'https://$id.example.com');
}
