import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

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

  void expectScopedStringCache(String key, {required String? serverId}) {
    final migrated = caches.get(key) as Map;
    expect(migrated['serverId'], serverId);
    expect(migrated['data'], isA<String>());
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
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'legacy conversation cache stays readable and migrates to the active server scope',
    () async {
      await saveServerConfigs(['server-a', 'server-b']);
      await storage.setActiveServerId('server-a');
      await seedLegacyJsonCache(HiveStoreKeys.localConversations, [
        _conversationJson('legacy-chat'),
      ]);

      final conversations = await storage.getLocalConversations();
      expect(conversations.map((conversation) => conversation.id), [
        'legacy-chat',
      ]);

      expectScopedStringCache(
        HiveStoreKeys.localConversations,
        serverId: 'server-a',
      );

      await storage.setActiveServerId('server-b');
      expect(await storage.getLocalConversations(), isEmpty);
    },
  );

  test(
    'legacy conversation cache read without an active server is quarantined from later server scopes',
    () async {
      await saveServerConfigs(['server-a']);
      await seedLegacyJsonCache(HiveStoreKeys.localConversations, [
        _conversationJson('legacy-chat'),
      ]);

      final conversations = await storage.getLocalConversations();
      expect(conversations.map((conversation) => conversation.id), [
        'legacy-chat',
      ]);

      expectScopedStringCache(HiveStoreKeys.localConversations, serverId: null);

      await storage.setActiveServerId('server-a');
      expect(await storage.getLocalConversations(), isEmpty);
    },
  );

  test(
    'legacy conversation cache with a stale active server id is quarantined instead of rebound',
    () async {
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('removed-server');
      await seedLegacyJsonCache(HiveStoreKeys.localConversations, [
        _conversationJson('legacy-chat'),
      ]);

      final conversations = await storage.getLocalConversations();
      expect(conversations.map((conversation) => conversation.id), [
        'legacy-chat',
      ]);

      expectScopedStringCache(HiveStoreKeys.localConversations, serverId: null);

      await storage.setActiveServerId('server-a');
      expect(await storage.getLocalConversations(), isEmpty);
    },
  );

  test(
    'legacy folder cache stays readable and migrates to the active server scope',
    () async {
      await saveServerConfigs(['server-a', 'server-b']);
      await storage.setActiveServerId('server-a');
      await seedLegacyJsonCache(HiveStoreKeys.localFolders, [
        {'id': 'legacy-folder', 'name': 'Legacy Folder'},
      ]);

      final folders = await storage.getLocalFolders();
      expect(folders.map((folder) => folder.id), ['legacy-folder']);

      expectScopedStringCache(HiveStoreKeys.localFolders, serverId: 'server-a');

      await storage.setActiveServerId('server-b');
      expect(await storage.getLocalFolders(), isEmpty);
    },
  );

  test(
    'legacy folder cache read without an active server is quarantined from later server scopes',
    () async {
      await saveServerConfigs(['server-a']);
      await seedLegacyJsonCache(HiveStoreKeys.localFolders, [
        {'id': 'legacy-folder', 'name': 'Legacy Folder'},
      ]);

      final folders = await storage.getLocalFolders();
      expect(folders.map((folder) => folder.id), ['legacy-folder']);

      expectScopedStringCache(HiveStoreKeys.localFolders, serverId: null);

      await storage.setActiveServerId('server-a');
      expect(await storage.getLocalFolders(), isEmpty);
    },
  );

  test(
    'legacy folder cache with a stale active server id is quarantined instead of rebound',
    () async {
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('removed-server');
      await seedLegacyJsonCache(HiveStoreKeys.localFolders, [
        {'id': 'legacy-folder', 'name': 'Legacy Folder'},
      ]);

      final folders = await storage.getLocalFolders();
      expect(folders.map((folder) => folder.id), ['legacy-folder']);

      expectScopedStringCache(HiveStoreKeys.localFolders, serverId: null);

      await storage.setActiveServerId('server-a');
      expect(await storage.getLocalFolders(), isEmpty);
    },
  );

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
    'fresh scoped cache writes with a stale active server id are quarantined',
    () async {
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('removed-server');

      await storage.saveLocalConversations([
        Conversation.fromJson(_conversationJson('fresh-chat')),
      ]);

      final stored = caches.get(HiveStoreKeys.localConversations) as Map;
      expect(stored['serverId'], isNull);
      expect(stored['data'], isA<String>());

      await storage.setActiveServerId('server-a');
      expect(await storage.getLocalConversations(), isEmpty);
    },
  );

  test('sync transport cache ignores stale active server ids', () async {
    await saveServerConfigs(['server-a']);
    await storage.setActiveServerId('removed-server');
    await caches.put(HiveStoreKeys.localTransportOptions, {
      'data': jsonEncode({'allowPolling': false, 'allowWebsocketOnly': true}),
      'serverId': 'removed-server',
    });

    final options = storage.getLocalTransportOptionsSync();

    expect(options, isNull);
  });
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
