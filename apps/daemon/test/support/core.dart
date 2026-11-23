import 'dart:async';
import 'dart:io';

import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/ports.dart';
import 'package:conduit_core/services/settings_service.dart'
    show AppSettingsHostDefaults;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/ports/worker.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:hive_ce/hive.dart';

/// The core as the service tests host it, with nothing of the desktop's:
/// preferences and credentials in memory, Hive and the account databases
/// in [dataDir], connectivity the test reports, and the desktop's policy
/// values so what the tests expect is unchanged.
Future<CoreRuntime> startTestCore(Directory dataDir) async {
  // `PreferencesStore` is process-wide and keeps the first store it loads,
  // so each runtime gets its own rather than one an earlier test left.
  PreferencesStore.debugReset();
  PreferencesStore.installLoader(() async => InMemoryKeyValueStore());
  await PreferencesStore.ensureInitialized();

  Hive.init('${dataDir.path}/hive');
  final preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
  final caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
  final attachmentQueue = await Hive.openBox<dynamic>(
    HiveBoxNames.attachmentQueue,
  );
  final metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);
  final boxes = <Box<dynamic>>[preferences, caches, attachmentQueue, metadata];

  final connectivity = TestConnectivity();
  return CoreRuntime.start(
    host: CoreHostBindings(
      secureStore: InMemorySecureKeyValueStore(),
      hiveBoxes: HiveBoxes(
        preferences: preferences,
        caches: caches,
        attachmentQueue: attachmentQueue,
        metadata: metadata,
      ),
      databaseOpener: _TestDatabases(Directory('${dataDir.path}/db')),
      worker: const DaemonWorkerPort(),
      connectivity: connectivity,
      reportNetwork: connectivity.report,
      close: () async {
        await connectivity.dispose();
        for (final box in boxes) {
          await box.close();
        }
      },
    ),
    policy: const CoreHostPolicy(
      settingsDefaults: AppSettingsHostDefaults(
        sendOnEnter: true,
        notificationsEnabled: true,
      ),
      readAloudLiveDeviceSpeech: true,
    ),
  );
}

/// Online until the test reports otherwise ([report]).
final class TestConnectivity implements ConnectivityPort {
  final StreamController<bool> _changes = StreamController<bool>.broadcast();
  bool _online = true;

  void report(bool online) {
    if (online == _online) return;
    _online = online;
    _changes.add(online);
  }

  @override
  Future<bool> hasNetworkInterface() async => _online;

  @override
  Stream<bool> get onChanged => _changes.stream;

  Future<void> dispose() => _changes.close();
}

/// A data layout in [root], as the desktop lays out its user data.
final class TestPaths implements PathsPort {
  TestPaths(this.root);

  final Directory root;

  Directory _dir(String name) =>
      Directory('${root.path}/$name')..createSync(recursive: true);

  @override
  Future<Directory> applicationSupport() async => root;

  @override
  Future<Directory> cache() async => _dir('cache');

  @override
  Future<Directory> logs() async => _dir('logs');

  @override
  Future<Directory> staging() async => _dir('staging');
}

/// Each account's database in a file of its own, as on the desktop.
final class _TestDatabases implements DatabaseOpenerPort {
  _TestDatabases(this._directory);

  final Directory _directory;

  @override
  QueryExecutor open(String serverId) {
    _directory.createSync(recursive: true);
    return NativeDatabase.createInBackground(
      File('${_directory.path}/$serverId.sqlite'),
    );
  }

  @override
  Future<Directory> databaseDirectory() async =>
      _directory..createSync(recursive: true);
}

/// A data layout that exists nowhere, for a session that never reaches it.
const DaemonPaths testDaemonPaths = DaemonPaths(
  userData: '/conduit-test',
  database: '/conduit-test/db',
  cache: '/conduit-test/cache',
  logs: '/conduit-test/logs',
  staging: '/conduit-test/staging',
);
