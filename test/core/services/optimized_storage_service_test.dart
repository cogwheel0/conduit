import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/core/database/app_database.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/socket_transport_availability.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/persistence/hive_boxes.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/cache_manager.dart';
import 'package:conduit/core/services/optimized_storage_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  final secureStorageOperations = <String>[];
  final secureStorageFailureCountdowns = <String, int>{};
  final secureStorageOperationEntered = <String, Completer<void>>{};
  final secureStorageOperationGates = <String, Completer<void>>{};
  final secureStorageSnapshotReadsBeforeGate = <String>{};

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
          final operation = '${methodCall.method}:$key';
          secureStorageOperations.add(operation);
          final snapshotReadBeforeGate =
              methodCall.method == 'read' &&
              key != null &&
              secureStorageSnapshotReadsBeforeGate.contains(operation);
          final snapshottedReadValue = snapshotReadBeforeGate
              ? secureStorageValues[key]
              : null;
          final entered = secureStorageOperationEntered[operation];
          if (entered != null && !entered.isCompleted) entered.complete();
          final gate = secureStorageOperationGates[operation];
          if (gate != null) await gate.future;
          final remainingUntilFailure =
              secureStorageFailureCountdowns[operation];
          if (remainingUntilFailure != null) {
            if (remainingUntilFailure <= 1) {
              secureStorageFailureCountdowns.remove(operation);
              throw PlatformException(
                code: 'injected-operation-failure',
                message: operation,
              );
            }
            secureStorageFailureCountdowns[operation] =
                remainingUntilFailure - 1;
          }
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
              return snapshotReadBeforeGate
                  ? snapshottedReadValue
                  : secureStorageValues[key];
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
    secureStorageOperations.clear();
    secureStorageFailureCountdowns.clear();
    secureStorageOperationEntered.clear();
    secureStorageOperationGates.clear();
    secureStorageSnapshotReadsBeforeGate.clear();
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
      final readsAfterSetup = secureStorageReadCounts['server_configs_v2'] ?? 0;

      expect(await storage.getActiveServerId(), 'server-a');
      expect(await storage.getActiveServerId(), 'server-a');
      expect(await storage.getActiveServerId(), 'server-a');

      expect(
        secureStorageReadCounts['server_configs_v2'] ?? 0,
        readsAfterSetup,
      );
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
    final readsBeforeFailures =
        secureStorageReadCounts['server_configs_v2'] ?? 0;

    expect(await storage.getServerConfigs(), isEmpty);
    expect(
      secureStorageReadCounts['server_configs_v2'],
      readsBeforeFailures + 2,
    );

    await expectLater(
      storage.stageServerConfigCandidate(_serverConfig('candidate')),
      throwsA(isA<PlatformException>()),
    );
    expect(
      secureStorageReadCounts['server_configs_v2'],
      readsBeforeFailures + 3,
    );

    secureStorageReadErrors.remove('server_configs_v2');

    final configs = await storage.getServerConfigs();

    expect(configs.map((config) => config.id), ['server-a']);
    expect(
      secureStorageReadCounts['server_configs_v2'],
      readsBeforeFailures + 4,
    );
  });

  test(
    'serverConfigsProvider exposes Keychain failure and recovers after invalidation',
    () async {
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
        message: 'temporarily unavailable',
      );
      final readsBefore = secureStorageReadCounts['server_configs_v2'] ?? 0;
      final container = ProviderContainer(
        overrides: [optimizedStorageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(serverConfigsProvider.future),
        throwsA(isA<PlatformException>()),
      );
      expect(secureStorageReadCounts['server_configs_v2'], readsBefore + 2);

      secureStorageReadErrors.remove('server_configs_v2');
      container.invalidate(serverConfigsProvider);

      final recovered = await container.read(serverConfigsProvider.future);
      expect(recovered.map((config) => config.id), ['server-a']);
      expect(secureStorageReadCounts['server_configs_v2'], readsBefore + 3);
    },
  );

  test(
    'active server validation does not cache null after a Keychain failure',
    () async {
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('server-a');
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
        message: 'temporarily unavailable',
      );
      final readsBefore = secureStorageReadCounts['server_configs_v2'] ?? 0;

      expect(await storage.getActiveServerId(), isNull);
      expect(
        PreferencesStore.getString(PreferenceKeys.activeServerId),
        'server-a',
      );
      expect(secureStorageReadCounts['server_configs_v2'], readsBefore + 2);

      secureStorageReadErrors.remove('server_configs_v2');
      expect(await storage.getActiveServerId(), 'server-a');
      expect(await storage.getActiveServerId(), 'server-a');
      expect(secureStorageReadCounts['server_configs_v2'], readsBefore + 3);
    },
  );

  test(
    'delayed token read cannot repopulate cache after a confirmed delete',
    () async {
      secureStorageValues['auth_token_v2'] = 'old-token';
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
      final readEntered = Completer<void>();
      final releaseRead = Completer<void>();
      secureStorageOperationEntered['read:auth_token_v2'] = readEntered;
      secureStorageOperationGates['read:auth_token_v2'] = releaseRead;
      secureStorageSnapshotReadsBeforeGate.add('read:auth_token_v2');

      final oldRead = storage.getAuthToken();
      await readEntered.future;
      final deletion = storage.deleteAuthToken();
      releaseRead.complete();

      expect(await oldRead, 'old-token');
      await deletion;
      final readsAfterDelete = secureStorageReadCounts['auth_token_v2'] ?? 0;
      expect(await storage.getAuthToken(), isNull);
      expect(secureStorageReadCounts['auth_token_v2'] ?? 0, readsAfterDelete);
      expect(secureStorageValues.containsKey('auth_token_v2'), isFalse);
    },
  );

  test(
    'delayed credentials read cannot restore the positive presence cache after delete',
    () async {
      await storage.saveCredentials(
        serverId: 'server-a',
        username: 'old-user',
        password: 'old-password',
      );
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
      final readEntered = Completer<void>();
      final releaseRead = Completer<void>();
      secureStorageOperationEntered['read:user_credentials_v2'] = readEntered;
      secureStorageOperationGates['read:user_credentials_v2'] = releaseRead;
      secureStorageSnapshotReadsBeforeGate.add('read:user_credentials_v2');

      final oldRead = storage.getSavedCredentials();
      await readEntered.future;
      final deletion = storage.deleteSavedCredentials();
      releaseRead.complete();

      expect((await oldRead)?['username'], 'old-user');
      await deletion;
      final readsAfterDelete =
          secureStorageReadCounts['user_credentials_v2'] ?? 0;
      expect(await storage.hasCredentials(), isFalse);
      expect(
        secureStorageReadCounts['user_credentials_v2'] ?? 0,
        readsAfterDelete,
      );
      expect(secureStorageValues.containsKey('user_credentials_v2'), isFalse);
    },
  );

  test(
    'delayed server config read cannot overwrite a newer saved config cache',
    () async {
      final oldConfig = _serverConfig('server-old');
      final newConfig = _serverConfig('server-new');
      await storage.saveServerConfigs([oldConfig]);
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
      final readEntered = Completer<void>();
      final releaseRead = Completer<void>();
      secureStorageOperationEntered['read:server_configs_v2'] = readEntered;
      secureStorageOperationGates['read:server_configs_v2'] = releaseRead;
      secureStorageSnapshotReadsBeforeGate.add('read:server_configs_v2');

      final oldRead = storage.getServerConfigs();
      await readEntered.future;
      final save = storage.saveServerConfigs([newConfig]);
      releaseRead.complete();

      expect(await oldRead, [oldConfig]);
      await save;
      final readsAfterSave = secureStorageReadCounts['server_configs_v2'] ?? 0;
      expect(await storage.getServerConfigs(), [newConfig]);
      expect(secureStorageReadCounts['server_configs_v2'] ?? 0, readsAfterSave);
    },
  );

  test('transient auth reads are not negative-cached', () async {
    secureStorageValues['auth_token_v2'] = 'recovered-token';
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
    secureStorageReadErrors['auth_token_v2'] = PlatformException(
      code: 'read-failed',
    );
    final readsBefore = secureStorageReadCounts['auth_token_v2'] ?? 0;

    expect(await storage.getAuthToken(), isNull);
    expect(secureStorageReadCounts['auth_token_v2'], readsBefore + 2);

    secureStorageReadErrors.remove('auth_token_v2');
    expect(await storage.getAuthToken(), 'recovered-token');
    expect(secureStorageReadCounts['auth_token_v2'], readsBefore + 3);
  });

  test(
    'transient credential reads are retried and not negative-cached',
    () async {
      await storage.saveCredentials(
        serverId: 'server-a',
        username: 'recovered-user',
        password: 'password',
      );
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
      secureStorageReadErrors['user_credentials_v2'] = PlatformException(
        code: 'read-failed',
      );
      final readsBefore = secureStorageReadCounts['user_credentials_v2'] ?? 0;

      expect(await storage.getSavedCredentials(), isNull);
      expect(secureStorageReadCounts['user_credentials_v2'], readsBefore + 2);

      await expectLater(
        storage.getSavedCredentialsStrict(),
        throwsA(isA<PlatformException>()),
      );
      expect(secureStorageReadCounts['user_credentials_v2'], readsBefore + 4);

      secureStorageReadErrors.remove('user_credentials_v2');
      expect(
        (await storage.getSavedCredentials())?['username'],
        'recovered-user',
      );
      expect(secureStorageReadCounts['user_credentials_v2'], readsBefore + 5);
    },
  );

  test(
    'confirmed credential absence is negative-cached after one strict read',
    () async {
      final readsBefore = secureStorageReadCounts['user_credentials_v2'] ?? 0;

      expect(await storage.getSavedCredentialsStrict(), isNull);
      expect(await storage.getSavedCredentialsStrict(), isNull);

      expect(
        secureStorageReadCounts['user_credentials_v2'] ?? 0,
        readsBefore + 1,
      );
    },
  );

  test('strict credential read recovers from one transient failure', () async {
    await storage.saveCredentials(
      serverId: 'server-a',
      username: 'recovered-user',
      password: 'password',
    );
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
    secureStorageOperations.clear();
    secureStorageFailureCountdowns['read:user_credentials_v2'] = 1;
    final readsBefore = secureStorageReadCounts['user_credentials_v2'] ?? 0;

    expect(
      (await storage.getSavedCredentialsStrict())?['username'],
      'recovered-user',
    );
    expect(secureStorageReadCounts['user_credentials_v2'], readsBefore + 1);
    expect(
      secureStorageOperations
          .where((operation) => operation == 'read:user_credentials_v2')
          .length,
      2,
    );
  });

  test(
    'confirmed token absence is negative-cached after one strict read',
    () async {
      final readsBefore = secureStorageReadCounts['auth_token_v2'] ?? 0;

      expect(await storage.getAuthTokenStrict(), isNull);
      expect(await storage.getAuthTokenStrict(), isNull);

      expect(secureStorageReadCounts['auth_token_v2'], readsBefore + 1);
    },
  );

  test('failed token delete remains fail-closed in this process', () async {
    await storage.saveAuthToken('retained-by-keychain');
    secureStorageFailureCountdowns['delete:auth_token_v2'] = 1;
    final readsBefore = secureStorageReadCounts['auth_token_v2'] ?? 0;

    await expectLater(
      storage.deleteAuthToken(),
      throwsA(isA<PlatformException>()),
    );

    expect(secureStorageValues['auth_token_v2'], 'retained-by-keychain');
    storage.clearCache();
    expect(await storage.getAuthToken(), isNull);
    expect(await storage.getAuthTokenStrict(), isNull);
    expect(secureStorageReadCounts['auth_token_v2'] ?? 0, readsBefore);
    expect(
      await storage.deleteAuthTokenIfMatches('retained-by-keychain'),
      isTrue,
    );
    expect(secureStorageValues.containsKey('auth_token_v2'), isFalse);
  });

  test('token compare-delete propagates exhausted Keychain reads', () async {
    await storage.saveAuthToken('rejected-token');
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
    secureStorageOperations.clear();
    secureStorageReadErrors['auth_token_v2'] = PlatformException(
      code: 'keychain-unavailable',
    );

    await expectLater(
      storage.deleteAuthTokenIfMatches('rejected-token'),
      throwsA(isA<PlatformException>()),
    );

    expect(secureStorageValues['auth_token_v2'], 'rejected-token');
    expect(
      secureStorageOperations
          .where((operation) => operation == 'read:auth_token_v2')
          .length,
      2,
    );
    expect(secureStorageOperations, isNot(contains('delete:auth_token_v2')));
  });

  test(
    'failed credential delete leaves the presence cache fail-closed',
    () async {
      await storage.saveCredentials(
        serverId: 'server-a',
        username: 'user',
        password: 'password',
      );
      secureStorageFailureCountdowns['delete:user_credentials_v2'] = 1;
      final readsBefore = secureStorageReadCounts['user_credentials_v2'] ?? 0;

      await expectLater(
        storage.deleteSavedCredentials(),
        throwsA(isA<PlatformException>()),
      );

      expect(secureStorageValues.containsKey('user_credentials_v2'), isTrue);
      storage.clearCache();
      expect(await storage.hasCredentials(), isFalse);
      expect(await storage.getSavedCredentialsStrict(), isNull);
      expect(secureStorageReadCounts['user_credentials_v2'] ?? 0, readsBefore);
      expect(
        await storage.deleteSavedCredentialsIfMatches(const {
          'serverId': 'server-a',
          'username': 'user',
          'password': 'password',
        }),
        isTrue,
      );
      expect(secureStorageValues.containsKey('user_credentials_v2'), isFalse);
    },
  );

  test(
    'credential compare-delete propagates exhausted Keychain reads',
    () async {
      await storage.saveCredentials(
        serverId: 'server-a',
        username: 'rejected-user',
        password: 'rejected-password',
      );
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
      secureStorageOperations.clear();
      secureStorageReadErrors['user_credentials_v2'] = PlatformException(
        code: 'keychain-unavailable',
      );

      await expectLater(
        storage.deleteSavedCredentialsIfMatches(const {
          'serverId': 'server-a',
          'username': 'rejected-user',
          'password': 'rejected-password',
        }),
        throwsA(isA<PlatformException>()),
      );

      expect(secureStorageValues.containsKey('user_credentials_v2'), isTrue);
      expect(
        secureStorageOperations
            .where((operation) => operation == 'read:user_credentials_v2')
            .length,
        2,
      );
      expect(
        secureStorageOperations,
        isNot(contains('delete:user_credentials_v2')),
      );
    },
  );

  test(
    'active server id recomputation is persisted across later config saves',
    () async {
      await storage.setActiveServerId('server-a');
      await storage.saveServerConfigs([_serverConfig('server-b')]);

      expect(await storage.getActiveServerId(), 'server-b');

      await storage.saveServerConfigs([
        _serverConfig('server-a'),
        _serverConfig('server-b'),
      ]);

      expect(await storage.getActiveServerId(), 'server-b');
    },
  );

  test('fenced token save removes its write when ownership changes', () async {
    secureStorageOperations.clear();
    var checks = 0;

    final saved = await storage.saveAuthTokenIfCurrent(
      'stale-token',
      canCommit: () => ++checks == 1,
    );

    expect(saved, isFalse);
    expect(await storage.getAuthToken(), isNull);
    expect(secureStorageOperations, [
      'write:auth_token_v2',
      'delete:auth_token_v2',
    ]);
  });

  test(
    'candidate discard is transaction-owned and normal edits supersede it',
    () async {
      final previous = [_serverConfig('server-a').copyWith(isActive: true)];
      final candidate = _serverConfig(
        'server-candidate',
      ).copyWith(isActive: true);
      await storage.saveServerConfigs(previous);
      await storage.setActiveServerId('server-a');
      var snapshot = await storage.stageServerConfigCandidate(candidate);

      expect(
        await storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: snapshot.transactionId,
        ),
        isTrue,
      );
      expect(await storage.getServerConfigs(), previous);

      final older = await storage.stageServerConfigCandidate(candidate);
      final newerCandidate = _serverConfig('newer-candidate');
      final newer = await storage.stageServerConfigCandidate(newerCandidate);
      expect(
        await storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: older.transactionId,
        ),
        isFalse,
      );
      expect(
        await storage.discardServerConfigCandidate(
          candidate: newerCandidate,
          transactionId: newer.transactionId,
        ),
        isTrue,
      );
      expect(await storage.getServerConfigs(), previous);

      snapshot = await storage.stageServerConfigCandidate(candidate);
      final edited = _serverConfig('server-newer');
      await storage.saveServerConfigs([edited]);
      expect(
        await storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: snapshot.transactionId,
        ),
        isFalse,
      );
      expect(await storage.getServerConfigs(), [edited]);
    },
  );

  test(
    'proxy transaction preserves prior configs and publishes consistent auth',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId('server-a');
      await storage.saveAuthToken('previous-token');
      await storage.saveCredentials(
        serverId: previous.id,
        username: 'account-a',
        password: 'account-a-secret',
      );
      final candidate = _serverConfig(
        'server-candidate',
      ).copyWith(apiKey: 'candidate-token', isActive: true);

      final snapshot = await storage.stageServerConfigCandidate(candidate);
      var published = false;
      final committed = await storage.commitServerConfigCandidateSession(
        candidate: candidate,
        transactionId: snapshot.transactionId,
        token: 'candidate-token',
        canCommit: () => true,
        publish: () => published = true,
      );

      expect(committed, isTrue);
      expect(published, isTrue);
      expect(await storage.getServerConfigs(), [
        previous.copyWith(isActive: false),
        candidate.copyWith(apiKey: null, isActive: true),
      ]);
      expect(await storage.getActiveServerId(), candidate.id);
      expect(await storage.getAuthToken(), 'candidate-token');
      expect(await storage.getSavedCredentials(), isNull);
    },
  );

  test(
    'non-remembered foreground session removes the prior credential owner',
    () async {
      final accountA = _serverConfig('server-a');
      final accountB = _serverConfig('server-b').copyWith(isActive: true);
      await storage.saveServerConfigs([accountA, accountB]);
      await storage.setActiveServerId(accountB.id);
      await storage.saveCredentials(
        serverId: accountA.id,
        username: 'account-a',
        password: 'account-a-secret',
      );
      final ownership = await storage.captureServerSessionOwnership(
        validatedConfig: accountB,
        requireActive: true,
      );

      expect(
        await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'account-b-token',
          canCommit: () => true,
          publish: () {},
        ),
        isTrue,
      );

      // Token invalidation for B now has no account-A credential to replay or
      // use to reactivate A silently.
      expect(await storage.getSavedCredentials(), isNull);
      expect(await storage.getAuthToken(), 'account-b-token');
      expect(await storage.getActiveServerId(), accountB.id);
    },
  );

  test(
    'failed foreground session restores the prior credential payload',
    () async {
      final accountA = _serverConfig('server-a');
      final accountB = _serverConfig('server-b').copyWith(isActive: true);
      await storage.saveServerConfigs([accountA, accountB]);
      await storage.setActiveServerId(accountB.id);
      await storage.saveCredentials(
        serverId: accountA.id,
        username: 'account-a',
        password: 'account-a-secret',
      );
      final previousCredentials = await storage.getSavedCredentials();
      final ownership = await storage.captureServerSessionOwnership(
        validatedConfig: accountB,
        requireActive: true,
      );

      await expectLater(
        storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'account-b-token',
          canCommit: () => true,
          publish: () => throw StateError('publish failed'),
        ),
        throwsA(isA<StateError>()),
      );

      expect(await storage.getSavedCredentials(), previousCredentials);
      expect(await storage.getAuthToken(), isNull);
    },
  );

  test('rollback preserves a pre-existing credential read fence', () async {
    final accountA = _serverConfig('server-a');
    final accountB = _serverConfig('server-b').copyWith(isActive: true);
    await storage.saveServerConfigs([accountA, accountB]);
    await storage.setActiveServerId(accountB.id);
    await storage.saveCredentials(
      serverId: accountA.id,
      username: 'account-a',
      password: 'retained-keychain-secret',
    );
    secureStorageFailureCountdowns['delete:user_credentials_v2'] = 1;
    await expectLater(
      storage.deleteSavedCredentials(),
      throwsA(isA<PlatformException>()),
    );
    // The failed delete leaves bytes in the mocked Keychain, but the
    // process-local fence must make that payload an absent rollback baseline.
    expect(secureStorageValues['user_credentials_v2'], isNotNull);
    expect(await storage.getSavedCredentials(), isNull);

    final ownership = await storage.captureServerSessionOwnership(
      validatedConfig: accountB,
      requireActive: true,
    );
    await expectLater(
      storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'account-b-token',
        rememberedCredentials: const {
          'serverId': 'server-b',
          'username': 'account-b',
          'password': 'candidate-secret',
        },
        canCommit: () => true,
        publish: () => throw StateError('publish failed'),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await storage.getSavedCredentials(), isNull);
    expect(await storage.hasCredentials(), isFalse);
    expect(secureStorageValues['user_credentials_v2'], isNull);
  });

  test('superseded proxy commit rolls every durable key back', () async {
    final previous = _serverConfig('server-a').copyWith(isActive: true);
    final candidate = _serverConfig(
      'server-candidate',
    ).copyWith(apiKey: 'candidate-token', isActive: true);
    await storage.saveServerConfigs([previous]);
    await storage.setActiveServerId(previous.id);
    await storage.saveAuthToken('previous-token');
    await storage.saveCredentials(
      serverId: previous.id,
      username: 'previous-user',
      password: 'previous-password',
    );
    final previousCredentials = await storage.getSavedCredentials();
    final snapshot = await storage.stageServerConfigCandidate(candidate);
    secureStorageOperations.clear();
    var checks = 0;
    var published = false;

    final committed = await storage.commitServerConfigCandidateSession(
      candidate: candidate,
      transactionId: snapshot.transactionId,
      token: 'candidate-token',
      // Supersede after the candidate token was written. Rollback must first
      // clear that token, restore active/config ownership, and restore the old
      // token last so every possible termination prefix is unauthenticated or
      // internally consistent.
      // The transaction now re-checks ownership after both strict baseline
      // snapshots. The eighth check is immediately after the candidate token
      // write and before publication.
      canCommit: () => ++checks < 8,
      publish: () => published = true,
    );

    expect(committed, isFalse);
    expect(published, isFalse);
    expect(await storage.getServerConfigs(), [previous]);
    expect(await storage.getActiveServerId(), previous.id);
    expect(await storage.getAuthToken(), 'previous-token');
    expect(await storage.getSavedCredentials(), previousCredentials);
    expect(
      secureStorageOperations,
      containsAllInOrder([
        'delete:auth_token_v2',
        'delete:user_credentials_v2',
        'write:server_configs_v2',
        'write:auth_token_v2',
        'delete:auth_token_v2',
        'write:server_configs_v2',
        'write:user_credentials_v2',
        'write:auth_token_v2',
      ]),
    );
  });

  test(
    'proxy commit aborts before writes when the prior token snapshot fails',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final candidate = _serverConfig(
        'server-candidate',
      ).copyWith(apiKey: 'candidate-token', isActive: true);
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');

      // Re-instantiation expires the in-memory token cache without changing
      // durable state, modeling the strict Keychain read after a long-lived
      // app's cache TTL has elapsed.
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
      final snapshot = await storage.stageServerConfigCandidate(candidate);
      secureStorageOperations.clear();
      secureStorageReadErrors['auth_token_v2'] = PlatformException(
        code: 'read-failed',
        message: 'transient keychain failure',
      );

      await expectLater(
        storage.commitServerConfigCandidateSession(
          candidate: candidate,
          transactionId: snapshot.transactionId,
          token: 'candidate-token',
          canCommit: () => true,
          publish: () {},
        ),
        throwsA(isA<PlatformException>()),
      );

      expect(secureStorageOperations, ['read:auth_token_v2']);
      secureStorageReadErrors.remove('auth_token_v2');
      expect(await storage.getServerConfigs(), [previous]);
      expect(await storage.getActiveServerId(), previous.id);
      expect(await storage.getAuthToken(), 'previous-token');
    },
  );

  test(
    'proxy commit reports incomplete rollback and clears its stage marker',
    () async {
      final previous = _serverConfig('server-a').copyWith(
        isActive: true,
        customHeaders: const {
          'Cookie': 'proxy_session=must-not-survive',
          'Authorization': 'Bearer stale',
          'Proxy-Authorization': 'Basic stale',
          'api-key': 'stale-api-key',
          'X-Forwarded-Email': 'stale@example.test',
          'X-Auth-Request-User': 'stale-user',
          'X-Tenant': 'retained',
        },
      );
      final candidate = _serverConfig('server-candidate');
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      await storage.saveCredentials(
        serverId: previous.id,
        username: 'previous-user',
        password: 'previous-password',
      );
      final snapshot = await storage.stageServerConfigCandidate(candidate);
      secureStorageOperations.clear();
      // Let the forward config write succeed, fail the candidate-token write,
      // then fail the second config write while rollback is restoring the
      // baseline. The rollback must remain tokenless and identify uncertainty.
      secureStorageFailureCountdowns['write:auth_token_v2'] = 1;
      secureStorageFailureCountdowns['write:server_configs_v2'] = 2;
      var uncertaintyPublished = false;

      await expectLater(
        storage.commitServerConfigCandidateSession(
          candidate: candidate,
          transactionId: snapshot.transactionId,
          token: 'candidate-token',
          canCommit: () => true,
          publish: () {},
          onRollbackUncertain: () {
            uncertaintyPublished = true;
            throw StateError('uncertainty observer failed');
          },
        ),
        throwsA(isA<ServerConfigSessionRollbackException>()),
      );

      expect(await storage.getAuthToken(), isNull);
      expect(await storage.getSavedCredentials(), isNull);
      final failClosedConfig = (await storage.getServerConfigs()).single;
      expect(failClosedConfig.customHeaders, isEmpty);
      expect(uncertaintyPublished, isTrue);
      expect(storage.isUncommittedServerConfigCandidate(candidate), isFalse);
      expect(
        await storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: snapshot.transactionId,
        ),
        isFalse,
      );
    },
  );

  test(
    'existing session supersession at each owner write restores the exact baseline',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final target = _serverConfig('server-b');

      for (final failedCheck in const [5, 6]) {
        await storage.saveServerConfigs([previous, target]);
        await storage.setActiveServerId(previous.id);
        await storage.saveAuthToken('previous-token');
        final ownership = await storage.captureServerSessionOwnership(
          validatedConfig: target,
          requireActive: false,
        );
        expect(ownership, isNotNull);

        var checks = 0;
        var published = false;
        final committed = await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'candidate-token',
          canCommit: () => ++checks < failedCheck,
          publish: () => published = true,
        );

        expect(committed, isFalse, reason: 'failed check $failedCheck');
        expect(published, isFalse);
        expect(await storage.getServerConfigs(), [previous, target]);
        expect(await storage.getActiveServerId(), previous.id);
        expect(await storage.getAuthToken(), 'previous-token');
      }
    },
  );

  test(
    'existing session rejects A-B-A selection and same-id transport mutation',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final target = _serverConfig('server-b');
      await storage.saveServerConfigs([previous, target]);
      await storage.setActiveServerId(previous.id);

      final foregroundOwnership = await storage.captureServerSessionOwnership(
        validatedConfig: previous,
        requireActive: true,
      );
      expect(foregroundOwnership, isNotNull);
      await storage.setActiveServerId(target.id);
      await storage.setActiveServerId(previous.id);

      var published = false;
      expect(
        await storage.commitExistingServerSession(
          ownership: foregroundOwnership!,
          token: 'stale-token',
          canCommit: () => true,
          publish: () => published = true,
        ),
        isFalse,
      );
      expect(published, isFalse);
      expect(await storage.getAuthToken(), isNull);

      final savedOwnership = await storage.captureServerSessionOwnership(
        validatedConfig: target,
        requireActive: false,
      );
      expect(savedOwnership, isNotNull);
      final mutated = target.copyWith(
        url: 'https://changed.example/',
        customHeaders: const {'Authorization': 'changed'},
        allowSelfSignedCertificates: true,
        mtlsCertificateChainPem: 'changed-certificate',
        mtlsPrivateKeyPem: 'changed-private-key',
        mtlsPrivateKeyPassword: 'changed-password',
      );
      await storage.saveServerConfigs([previous, mutated]);

      expect(
        await storage.commitExistingServerSession(
          ownership: savedOwnership!,
          token: 'stale-token',
          canCommit: () => true,
          publish: () => published = true,
        ),
        isFalse,
      );
      expect(published, isFalse);
      expect(await storage.getAuthToken(), isNull);
    },
  );

  test(
    'existing session rejects replaced saved credentials before mutation',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final target = _serverConfig('server-b');
      await storage.saveServerConfigs([previous, target]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      await storage.saveCredentials(
        serverId: target.id,
        username: 'jwt_user',
        password: 'old-token',
        authType: 'token',
      );
      final expected = await storage.getSavedCredentials();
      final ownership = await storage.captureSavedServerSessionOwnership(
        target.id,
      );
      expect(ownership, isNotNull);
      expect(expected, isNotNull);

      await storage.saveCredentials(
        serverId: target.id,
        username: 'jwt_user',
        password: 'replacement-token',
        authType: 'token',
      );
      secureStorageOperations.clear();
      var published = false;

      expect(
        await storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'old-token',
          expectedSavedCredentials: expected,
          canCommit: () => true,
          publish: () => published = true,
        ),
        isFalse,
      );
      expect(published, isFalse);
      expect(await storage.getAuthToken(), 'previous-token');
      expect(
        (await storage.getSavedCredentials())?['password'],
        'replacement-token',
      );
      expect(secureStorageOperations, isNot(contains('delete:auth_token_v2')));
    },
  );

  test(
    'remembered credential and token rollback restores exact previous payload',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final target = _serverConfig('server-b');
      await storage.saveServerConfigs([previous, target]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      await storage.saveCredentials(
        serverId: previous.id,
        username: 'previous-user',
        password: 'previous-password',
        authType: 'sso',
      );
      final previousCredentials = await storage.getSavedCredentials();
      final ownership = await storage.captureServerSessionOwnership(
        validatedConfig: target,
        requireActive: false,
      );
      expect(ownership, isNotNull);

      var commitAllowed = true;
      final tokenWriteEntered = Completer<void>();
      final releaseTokenWrite = Completer<void>();
      secureStorageOperationEntered['write:auth_token_v2'] = tokenWriteEntered;
      secureStorageOperationGates['write:auth_token_v2'] = releaseTokenWrite;
      var published = false;
      final commit = storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'candidate-token',
        rememberedCredentials: {
          'serverId': target.id,
          'username': 'new-user',
          'password': 'new-password',
          'authType': 'credentials',
        },
        canCommit: () => commitAllowed,
        publish: () => published = true,
      );

      await tokenWriteEntered.future;
      commitAllowed = false;
      releaseTokenWrite.complete();

      expect(await commit, isFalse);
      expect(published, isFalse);
      expect(await storage.getServerConfigs(), [previous, target]);
      expect(await storage.getActiveServerId(), previous.id);
      expect(await storage.getAuthToken(), 'previous-token');
      expect(await storage.getSavedCredentials(), previousCredentials);
    },
  );

  test('publish failure rolls an existing session fully back', () async {
    final previous = _serverConfig('server-a').copyWith(isActive: true);
    final target = _serverConfig('server-b');
    await storage.saveServerConfigs([previous, target]);
    await storage.setActiveServerId(previous.id);
    await storage.saveAuthToken('previous-token');
    final ownership = await storage.captureServerSessionOwnership(
      validatedConfig: target,
      requireActive: false,
    );

    await expectLater(
      storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'candidate-token',
        canCommit: () => true,
        publish: () => throw StateError('publish failed'),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await storage.getServerConfigs(), [previous, target]);
    expect(await storage.getActiveServerId(), previous.id);
    expect(await storage.getAuthToken(), 'previous-token');
  });

  test(
    'uncertain logout-fence rollback restores only a sanitized tokenless owner',
    () async {
      final previous = _serverConfig('server-a').copyWith(
        isActive: true,
        customHeaders: const {
          'Cookie': 'proxy_session=stale',
          'X-Tenant': 'retained',
        },
        mtlsCertificateChainPem: 'baseline-certificate',
        mtlsCertificateLabel: 'baseline.crt',
        mtlsPrivateKeyPem: 'baseline-private-key',
        mtlsPrivateKeyLabel: 'baseline.key',
        mtlsPrivateKeyPassword: 'baseline-password',
      );
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      await storage.saveCredentials(
        serverId: previous.id,
        username: 'previous-user',
        password: 'previous-password',
      );
      final ownership = await storage.captureServerSessionOwnership(
        validatedConfig: previous,
        requireActive: true,
      );
      var poisoned = false;

      await expectLater(
        storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'candidate-token',
          canCommit: () => true,
          publish: () async {
            await Future<void>.delayed(Duration.zero);
            throw const ServerConfigSessionRollbackException(
              commitError: 'authenticated publication failed',
              rollbackError: 'logout fence restore failed',
            );
          },
          onRollbackUncertain: () => poisoned = true,
        ),
        throwsA(isA<ServerConfigSessionRollbackException>()),
      );

      expect(poisoned, isTrue);
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.hasCredentials(), isFalse);
      final restored = (await storage.getServerConfigs()).single;
      expect(restored.customHeaders, isEmpty);
      expect(restored.mtlsCertificateChainPem, isNull);
      expect(restored.mtlsCertificateLabel, isNull);
      expect(restored.mtlsPrivateKeyPem, isNull);
      expect(restored.mtlsPrivateKeyLabel, isNull);
      expect(restored.mtlsPrivateKeyPassword, isNull);
      expect(await storage.getActiveServerId(), previous.id);
    },
  );

  test(
    'existing session rollback uncertainty publishes poison and stays tokenless',
    () async {
      final previous = _serverConfig('server-a').copyWith(
        isActive: true,
        customHeaders: const {
          'Cookie': 'proxy_session=must-not-survive',
          'X-Tenant': 'retained',
        },
      );
      final target = _serverConfig('server-b');
      await storage.saveServerConfigs([previous, target]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      await storage.saveCredentials(
        serverId: previous.id,
        username: 'previous-user',
        password: 'previous-password',
      );
      final ownership = await storage.captureServerSessionOwnership(
        validatedConfig: target,
        requireActive: false,
      );
      secureStorageFailureCountdowns['write:auth_token_v2'] = 1;
      secureStorageFailureCountdowns['write:server_configs_v2'] = 2;
      var poisoned = false;

      await expectLater(
        storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'candidate-token',
          canCommit: () => true,
          publish: () {},
          onRollbackUncertain: () => poisoned = true,
        ),
        throwsA(isA<ServerConfigSessionRollbackException>()),
      );

      expect(poisoned, isTrue);
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.getSavedCredentials(), isNull);
      final failClosedConfigs = await storage.getServerConfigs();
      expect(
        failClosedConfigs.every((config) => config.customHeaders.isEmpty),
        isTrue,
      );
    },
  );

  test(
    'failed checked active-id write rolls back before candidate token',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final target = _serverConfig('server-b');
      await storage.saveServerConfigs([previous, target]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      final ownership = await storage.captureServerSessionOwnership(
        validatedConfig: target,
        requireActive: false,
      );
      final sharedPreferences = await SharedPreferences.getInstance();
      PreferencesStore.debugOverride(
        sharedPreferences,
        writeInterceptor: (preferences, key, value) async {
          if (key == PreferenceKeys.activeServerId && value == target.id) {
            return false;
          }
          return null;
        },
      );

      await expectLater(
        storage.commitExistingServerSession(
          ownership: ownership!,
          token: 'candidate-token',
          canCommit: () => true,
          publish: () {},
        ),
        throwsA(isA<StateError>()),
      );

      expect(await storage.getServerConfigs(), [previous, target]);
      expect(await storage.getActiveServerId(), previous.id);
      expect(await storage.getAuthToken(), 'previous-token');
      expect(secureStorageValues['auth_token_v2'], isNot('candidate-token'));
    },
  );

  test(
    'fresh server selection is bearer-tokenless and preserves exact candidate headers',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final target = _serverConfig('server-b').copyWith(
        apiKey: 'legacy-bearer',
        customHeaders: const {
          'Cookie': 'proxy_session=fresh-candidate',
          'X-OpenWebUI-Key': 'fresh-custom-key',
          'X-Tenant': 'fresh-routing-value',
        },
      );
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      await storage.saveCredentials(
        serverId: previous.id,
        username: 'previous-user',
        password: 'previous-password',
      );
      secureStorageOperations.clear();
      var publishedTokenless = false;

      await storage.selectUnauthenticatedServerConfig(
        target,
        publish: () {
          publishedTokenless =
              !secureStorageValues.containsKey('auth_token_v2') &&
              PreferencesStore.getString(PreferenceKeys.activeServerId) ==
                  target.id;
        },
      );

      expect(publishedTokenless, isTrue);
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.getSavedCredentials(), isNull);
      expect(await storage.getServerConfigs(), [
        target.copyWith(apiKey: null, isActive: true),
      ]);
      final tokenDelete = secureStorageOperations.indexOf(
        'delete:auth_token_v2',
      );
      final credentialsDelete = secureStorageOperations.indexOf(
        'delete:user_credentials_v2',
      );
      final configWrite = secureStorageOperations.indexOf(
        'write:server_configs_v2',
      );
      expect(tokenDelete, greaterThanOrEqualTo(0));
      expect(credentialsDelete, greaterThan(tokenDelete));
      expect(configWrite, greaterThan(credentialsDelete));
    },
  );

  test(
    'failed server-selection publication restores the prior session',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final target = _serverConfig('server-b');
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      await storage.saveCredentials(
        serverId: previous.id,
        username: 'previous-user',
        password: 'previous-password',
      );

      await expectLater(
        storage.selectUnauthenticatedServerConfig(
          target,
          publish: () => throw StateError('publication failed'),
        ),
        throwsA(isA<StateError>()),
      );

      expect(await storage.getServerConfigs(), [previous]);
      expect(await storage.getActiveServerId(), previous.id);
      expect(await storage.getAuthToken(), 'previous-token');
      expect(await storage.getSavedCredentials(), {
        'serverId': previous.id,
        'username': 'previous-user',
        'password': 'previous-password',
        'authType': 'credentials',
        'savedAt': isA<String>(),
      });
    },
  );

  test('superseded server selection rolls back after publication', () async {
    final previous = _serverConfig('server-a').copyWith(isActive: true);
    final target = _serverConfig('server-b');
    await storage.saveServerConfigs([previous]);
    await storage.setActiveServerId(previous.id);
    await storage.saveAuthToken('previous-token');
    var commitAllowed = true;
    var publishCalls = 0;

    final selected = await storage.selectUnauthenticatedServerConfig(
      target,
      canCommit: () => commitAllowed,
      publish: () {
        publishCalls++;
        commitAllowed = false;
      },
    );

    expect(selected, isFalse);
    expect(publishCalls, 1);
    expect(await storage.getServerConfigs(), [previous]);
    expect(await storage.getActiveServerId(), previous.id);
    expect(await storage.getAuthToken(), 'previous-token');
  });

  test('logout scrubs proxy cookies and legacy config bearer fields', () async {
    final config = _serverConfig('server-a').copyWith(
      apiKey: 'legacy-bearer',
      customHeaders: const {
        'Cookie': 'session=secret',
        'X-OpenWebUI-Key': 'arbitrary-custom-api-key',
        'X-Tenant': 'could-also-be-configured-as-an-api-key',
      },
      allowSelfSignedCertificates: true,
      mtlsCertificateChainPem: 'client-certificate',
      mtlsCertificateLabel: 'client.crt',
      mtlsPrivateKeyPem: 'client-private-key',
      mtlsPrivateKeyLabel: 'client.key',
      mtlsPrivateKeyPassword: 'private-key-password',
      isActive: true,
    );
    await storage.saveServerConfigs([config]);
    await storage.setActiveServerId(config.id);
    await storage.saveAuthToken('token');
    await storage.saveCredentials(
      serverId: config.id,
      username: 'user',
      password: 'password',
    );
    secureStorageOperations.clear();

    await storage.clearAuthData();

    expect(await storage.getAuthToken(), isNull);
    expect(await storage.getSavedCredentials(), isNull);
    expect(await storage.getServerConfigs(), [
      config.copyWith(
        apiKey: null,
        customHeaders: const {},
        mtlsCertificateChainPem: null,
        mtlsCertificateLabel: null,
        mtlsPrivateKeyPem: null,
        mtlsPrivateKeyLabel: null,
        mtlsPrivateKeyPassword: null,
      ),
    ]);
    expect(
      secureStorageOperations.indexOf('delete:auth_token_v2'),
      lessThan(secureStorageOperations.indexOf('write:server_configs_v2')),
    );
  });

  test('logout revokes a standalone mTLS identity', () async {
    final config = _serverConfig('mtls-only').copyWith(
      allowSelfSignedCertificates: true,
      mtlsCertificateChainPem: 'standalone-certificate',
      mtlsCertificateLabel: 'standalone.crt',
      mtlsPrivateKeyPem: 'standalone-private-key',
      mtlsPrivateKeyLabel: 'standalone.key',
      mtlsPrivateKeyPassword: 'standalone-password',
      isActive: true,
    );
    await storage.saveServerConfigs([config]);
    await storage.setActiveServerId(config.id);
    secureStorageOperations.clear();

    await storage.clearAuthData();

    final revoked = (await storage.getServerConfigs()).single;
    expect(revoked.allowSelfSignedCertificates, isTrue);
    expect(revoked.mtlsCertificateChainPem, isNull);
    expect(revoked.mtlsCertificateLabel, isNull);
    expect(revoked.mtlsPrivateKeyPem, isNull);
    expect(revoked.mtlsPrivateKeyLabel, isNull);
    expect(revoked.mtlsPrivateKeyPassword, isNull);
    expect(secureStorageOperations, contains('write:server_configs_v2'));
  });

  test(
    'logout attempts every fail-closed leg and rethrows the first error',
    () async {
      final config = _serverConfig('server-a').copyWith(
        apiKey: 'legacy-bearer',
        customHeaders: const {'COOKIE': 'session=secret', 'X-Tenant': 'tenant'},
        isActive: true,
      );
      await storage.saveServerConfigs([config]);
      await storage.setActiveServerId(config.id);
      await storage.saveAuthToken('token-that-keychain-retains');
      await storage.saveCredentials(
        serverId: config.id,
        username: 'user',
        password: 'password',
      );
      secureStorageFailureCountdowns['delete:auth_token_v2'] = 1;

      await check(storage.clearAuthData()).throws<PlatformException>();

      check(secureStorageValues).containsKey('auth_token_v2');
      check(secureStorageValues.containsKey('user_credentials_v2')).isFalse();
      check(
        await storage.getServerConfigs(),
      ).deepEquals([config.copyWith(apiKey: null, customHeaders: const {})]);
    },
  );

  test('config save persists its recomputed effective active id', () async {
    final previous = _serverConfig('server-a').copyWith(isActive: true);
    final replacement = _serverConfig('server-b').copyWith(isActive: true);
    await storage.saveServerConfigs([previous]);
    await storage.setActiveServerId(previous.id);

    await storage.saveServerConfigs([replacement]);

    check(
      PreferencesStore.getString(PreferenceKeys.activeServerId),
    ).equals(replacement.id);
    check(await storage.getActiveServerId()).equals(replacement.id);
  });

  test(
    'locked missing-server cleanup preserves credentials when the server exists',
    () async {
      final config = _serverConfig('server-a').copyWith(isActive: true);
      await storage.saveServerConfigs([config]);
      await storage.saveCredentials(
        serverId: config.id,
        username: 'user',
        password: 'password',
      );
      final expected = await storage.getSavedCredentials();

      expect(
        await storage.deleteSavedCredentialsIfMatchesAndServerMissing(
          expected!,
        ),
        isFalse,
      );
      expect(await storage.getSavedCredentials(), expected);
    },
  );

  test('staging snapshots the effective fallback active server', () async {
    final previous = _serverConfig('server-a').copyWith(isActive: true);
    final candidate = _serverConfig('server-candidate');
    await storage.saveServerConfigs([previous]);
    await PreferencesStore.put(
      PreferenceKeys.activeServerId,
      'dangling-server-id',
    );

    final snapshot = await storage.stageServerConfigCandidate(candidate);

    expect(snapshot.activeServerId, previous.id);
    expect(snapshot.configs, [previous]);
  });

  test(
    'process death after staging leaves durable session untouched',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final candidate = _serverConfig(
        'server-candidate',
      ).copyWith(apiKey: 'candidate-token', isActive: true);
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      await storage.stageServerConfigCandidate(candidate);

      // Re-instantiation models a terminated process: the in-memory candidate
      // marker is gone, while secure storage/preferences remain.
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

      expect(await storage.getServerConfigs(), [previous]);
      expect(await storage.getActiveServerId(), previous.id);
      expect(await storage.getAuthToken(), 'previous-token');
    },
  );

  test(
    'provider rebuild cannot publish or activate a staged proxy candidate',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final candidate = _serverConfig(
        'server-candidate',
      ).copyWith(isActive: true);
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId(previous.id);
      final snapshot = await storage.stageServerConfigCandidate(candidate);

      final container = ProviderContainer(
        overrides: [optimizedStorageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      // This is the rebuild that previously saw the sole isActive candidate
      // and persisted it before token ownership had been established.
      expect(await container.read(activeServerProvider.future), previous);
      expect(
        PreferencesStore.getString(PreferenceKeys.activeServerId),
        previous.id,
      );

      expect(
        await storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: snapshot.transactionId,
        ),
        isTrue,
      );
      expect(await storage.getServerConfigs(), [previous]);
    },
  );

  test(
    'same-id staged replacement keeps the durable active server published',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final candidate = previous.copyWith(
        name: 'Replacement',
        url: 'https://replacement.example',
        customHeaders: const {'X-Proxy': 'replacement'},
      );
      await storage.saveServerConfigs([previous]);
      await storage.setActiveServerId(previous.id);
      final snapshot = await storage.stageServerConfigCandidate(candidate);

      final container = ProviderContainer(
        overrides: [optimizedStorageServiceProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      expect(await container.read(activeServerProvider.future), previous);
      expect(await storage.getActiveServerId(), previous.id);
      expect(
        await storage.discardServerConfigCandidate(
          candidate: candidate,
          transactionId: snapshot.transactionId,
        ),
        isTrue,
      );
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

      var switchCompleted = false;
      final serverSwitch = storage.setActiveServerId('server-b').then((_) {
        switchCompleted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(switchCompleted, isFalse);

      releaseGate.complete();
      await cleanup;
      await serverSwitch;

      expect(storage.getLocalTransportOptionsSync(), optionsB);
      await storage.setActiveServerId('server-a');
      expect(storage.getLocalTransportOptionsSync(), isNull);
    },
  );

  test(
    'user cleanup cannot erase a newer queued authenticated user persistence',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final cleanupReleaseStarted = Completer<void>();
      final cleanupReleaseGate = Completer<void>();
      addTearDown(() {
        if (!cleanupReleaseGate.isCompleted) cleanupReleaseGate.complete();
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
          database: database,
          onRelease: () async {
            if (!cleanupReleaseStarted.isCompleted) {
              cleanupReleaseStarted.complete();
            }
            await cleanupReleaseGate.future;
          },
        ),
      );
      const user = User(
        id: 'new-session-user',
        username: 'new-user',
        email: 'new-user@example.test',
        role: 'user',
      );

      final cleanup = storage.clearUserScopedAuthData();
      await cleanupReleaseStarted.future;
      var persistenceCompleted = false;
      final persistence = storage
          .saveLocalUserWithAvatar(user, avatarUrl: 'new-avatar')
          .then((_) => persistenceCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(persistenceCompleted, isFalse);

      cleanupReleaseGate.complete();
      await cleanup;
      await persistence;

      final persisted = await storage.getLocalUserWithAvatar();
      expect(persisted?.id, user.id);
      expect(persisted?.profileImage, 'new-avatar');
    },
  );

  test(
    'clearAll propagates Keychain wipe failure and leaves auth tokenless',
    () async {
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('server-a');
      await storage.saveAuthToken('token');
      await storage.saveCredentials(
        serverId: 'server-a',
        username: 'user',
        password: 'password',
      );
      secureStorageFailureCountdowns['deleteAll:null'] = 1;

      await expectLater(storage.clearAll(), throwsA(isA<PlatformException>()));

      expect(secureStorageValues.containsKey('auth_token_v2'), isFalse);
      expect(secureStorageValues.containsKey('user_credentials_v2'), isFalse);
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.hasCredentials(), isFalse);
    },
  );

  test(
    'clearAll attempts every auth leg and rethrows the first failure',
    () async {
      final config = _serverConfig('server-a').copyWith(
        apiKey: 'legacy-bearer',
        customHeaders: const {
          'cOoKiE': 'proxy_session=must-not-survive',
          'X-Tenant': 'retained',
        },
        isActive: true,
      );
      await storage.saveServerConfigs([config]);
      await storage.setActiveServerId(config.id);
      await storage.saveAuthToken('token-that-first-delete-retains');
      await storage.saveCredentials(
        serverId: config.id,
        username: 'user',
        password: 'password',
      );
      secureStorageOperations.clear();
      secureStorageFailureCountdowns['delete:auth_token_v2'] = 1;
      secureStorageFailureCountdowns['delete:user_credentials_v2'] = 1;
      secureStorageFailureCountdowns['write:server_configs_v2'] = 1;
      secureStorageFailureCountdowns['deleteAll:null'] = 1;

      Object? caught;
      try {
        await storage.clearAll();
      } catch (error) {
        caught = error;
      }

      final failure = check(caught).isA<PlatformException>();
      failure
          .has((error) => error.message, 'message')
          .equals('delete:auth_token_v2');
      check(secureStorageOperations).contains('delete:user_credentials_v2');
      check(secureStorageOperations).contains('write:server_configs_v2');
      check(secureStorageOperations).contains('deleteAll:null');
      check(secureStorageValues).containsKey('auth_token_v2');
      check(secureStorageValues).containsKey('user_credentials_v2');
      check(await storage.getAuthToken()).isNull();
      check(await storage.hasCredentials()).isFalse();
      check(await storage.getServerConfigs()).isEmpty();
      check(await storage.getActiveServerId()).isNull();

      final storedConfigs =
          jsonDecode(secureStorageValues['server_configs_v2']!)
              as List<dynamic>;
      final storedConfig = ServerConfig.fromJson(storedConfigs.single);
      check(storedConfig.apiKey).isNull();
      check(
        storedConfig.customHeaders.keys
            .map((name) => name.toLowerCase())
            .contains('cookie'),
      ).isTrue();
      check(storedConfig.customHeaders['X-Tenant']).equals('retained');
    },
  );

  test(
    'failed wipe suppression survives cache expiry eviction and clearing until explicit resave',
    () async {
      storage = OptimizedStorageService(
        secureStorage: const FlutterSecureStorage(),
        boxes: HiveBoxes(
          preferences: preferences,
          caches: caches,
          attachmentQueue: attachmentQueue,
          metadata: metadata,
        ),
        workerManager: workerManager,
        cacheManager: CacheManager(maxEntries: 1),
        authTokenCacheTtl: Duration.zero,
        serverIdCacheTtl: Duration.zero,
        serverConfigsCacheTtl: Duration.zero,
        credentialsFlagCacheTtl: Duration.zero,
      );
      final retainedConfig = _serverConfig('server-a').copyWith(
        apiKey: 'retained-api-key',
        customHeaders: const {'Cookie': 'retained-proxy-cookie'},
        isActive: true,
      );
      await storage.saveServerConfigs([retainedConfig]);
      await storage.setActiveServerId(retainedConfig.id);
      await storage.saveAuthToken('retained-token');
      await storage.saveCredentials(
        serverId: retainedConfig.id,
        username: 'retained-user',
        password: 'retained-password',
      );
      secureStorageFailureCountdowns['delete:auth_token_v2'] = 1;
      secureStorageFailureCountdowns['delete:user_credentials_v2'] = 1;
      secureStorageFailureCountdowns['write:server_configs_v2'] = 1;
      secureStorageFailureCountdowns['deleteAll:null'] = 1;

      await expectLater(storage.clearAll(), throwsA(isA<PlatformException>()));
      // Model a retained/reintroduced platform preference independently of the
      // service cache. The process-local wipe fence must still hide it.
      await PreferencesStore.putChecked(
        PreferenceKeys.activeServerId,
        retainedConfig.id,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      storage.clearCache();

      expect(secureStorageValues['auth_token_v2'], 'retained-token');
      expect(secureStorageValues.containsKey('user_credentials_v2'), isTrue);
      expect(await storage.getAuthTokenStrict(), isNull);
      expect(await storage.getSavedCredentialsStrict(), isNull);
      expect(await storage.getServerConfigsStrict(), isEmpty);
      expect(await storage.getActiveServerId(), isNull);

      // A later cleanup pass must bypass both the suppression flag and the
      // negative cache so it can sanitize the retained platform payload.
      await storage.clearAuthData();
      final scrubbedConfigs =
          jsonDecode(secureStorageValues['server_configs_v2']!)
              as List<dynamic>;
      final scrubbedConfig = ServerConfig.fromJson(scrubbedConfigs.single);
      expect(scrubbedConfig.apiKey, isNull);
      expect(
        scrubbedConfig.customHeaders.keys.any(
          (name) => name.toLowerCase() == 'cookie',
        ),
        isFalse,
      );
      expect(scrubbedConfig.customHeaders, isEmpty);
      expect(await storage.getServerConfigsStrict(), isEmpty);

      final replacement = _serverConfig('server-b').copyWith(isActive: true);
      await storage.saveServerConfigs([replacement]);
      await storage.setActiveServerId(replacement.id);
      await storage.saveAuthToken('replacement-token');
      await storage.saveCredentials(
        serverId: replacement.id,
        username: 'replacement-user',
        password: 'replacement-password',
      );

      expect(await storage.getAuthTokenStrict(), 'replacement-token');
      expect(
        (await storage.getSavedCredentialsStrict())?['username'],
        'replacement-user',
      );
      expect(
        (await storage.getServerConfigsStrict()).single.id,
        replacement.id,
      );
      expect(await storage.getActiveServerId(), replacement.id);
    },
  );

  test(
    'clearAll queued behind a session commit cannot be followed by token resurrection',
    () async {
      final previous = _serverConfig('server-a').copyWith(isActive: true);
      final target = _serverConfig('server-b');
      await storage.saveServerConfigs([previous, target]);
      await storage.setActiveServerId(previous.id);
      await storage.saveAuthToken('previous-token');
      final ownership = await storage.captureServerSessionOwnership(
        validatedConfig: target,
        requireActive: false,
      );
      final tokenWriteEntered = Completer<void>();
      final releaseTokenWrite = Completer<void>();
      secureStorageOperationEntered['write:auth_token_v2'] = tokenWriteEntered;
      secureStorageOperationGates['write:auth_token_v2'] = releaseTokenWrite;

      var published = false;
      final commit = storage.commitExistingServerSession(
        ownership: ownership!,
        token: 'candidate-token',
        canCommit: () => true,
        publish: () => published = true,
      );
      await tokenWriteEntered.future;
      final wipe = storage.clearAll();
      releaseTokenWrite.complete();

      expect(await commit, isTrue);
      expect(published, isTrue);
      await wipe;
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.getServerConfigs(), isEmpty);
      expect(await storage.getActiveServerId(), isNull);
    },
  );

  test(
    'clearAll keeps its server owner until deferred Drift cleanup finishes',
    () async {
      final database = AppDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final resolutionStarted = Completer<void>();
      final resolutionGate = Completer<void>();
      addTearDown(() {
        if (!resolutionGate.isCompleted) resolutionGate.complete();
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
        databaseAccess: () async {
          if (!resolutionStarted.isCompleted) resolutionStarted.complete();
          await resolutionGate.future;
          if (PreferencesStore.getString(PreferenceKeys.activeServerId) !=
              'server-a') {
            return null;
          }
          return OptimizedStorageDatabaseHandle(database: database);
        },
      );
      await saveServerConfigs(['server-a']);
      await storage.setActiveServerId('server-a');
      await database.appCacheDao.setValue(
        HiveStoreKeys.localTools,
        'must-be-cleared',
      );

      final cleanup = storage.clearAll();
      await resolutionStarted.future;

      expect(
        PreferencesStore.getString(PreferenceKeys.activeServerId),
        'server-a',
      );
      resolutionGate.complete();
      await cleanup;

      expect(
        await database.appCacheDao.getValue(HiveStoreKeys.localTools),
        isNull,
      );
      expect(PreferencesStore.getString(PreferenceKeys.activeServerId), isNull);
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
