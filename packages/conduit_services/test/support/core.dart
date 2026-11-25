import 'dart:async';
import 'dart:io';

import 'package:conduit_core/database/app_database.dart' show AppDatabase;
import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider;
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/ports.dart';
import 'package:conduit_core/services/settings_service.dart'
    show AppSettingsHostDefaults;
import 'package:conduit_core/sync/outbox_drainer.dart'
    show outboxDrainGateProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:hive_ce/hive.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:test/test.dart' show addTearDown;

import 'fake_owui_auth_server.dart';

/// The core as the service tests host it, with nothing of the desktop's:
/// preferences and credentials in memory, Hive and the account databases
/// in [dataDir], connectivity the test reports, and the desktop's policy
/// values so what the tests expect is unchanged.
///
/// [interceptDatabase], given a database's file name, returns what that
/// database's queries and close go through (null for none). [databases]
/// replaces the account databases in [dataDir], [preferences] the
/// preferences kept in memory, and the schedulers and [lifecycle] the
/// root's own. [outboxDrainGate], when given, is what every outbox drain
/// waits for first ([outboxDrainGateProvider]): a test that must decide
/// when this device's changes reach the server passes one it opens itself.
Future<CoreRuntime> startTestCore(
  Directory dataDir, {
  QueryInterceptor? Function(String fileName)? interceptDatabase,
  DatabaseOpenerPort? databases,
  KeyValueStore? preferences,
  FlushScheduler? flushScheduler,
  PostFrameScheduler? postFrameScheduler,
  AppLifecyclePort? lifecycle,
  Future<void> Function()? outboxDrainGate,
}) async {
  // `PreferencesStore` is process-wide and keeps the first store it loads,
  // so each runtime gets its own rather than one an earlier test left.
  PreferencesStore.debugReset();
  PreferencesStore.installLoader(
    () async => preferences ?? InMemoryKeyValueStore(),
  );
  await PreferencesStore.ensureInitialized();

  Hive.init('${dataDir.path}/hive');
  final connectivity = TestConnectivity();
  final boxes = <Box<dynamic>>[];
  // Releases what was acquired: the runtime's own close, or a later step
  // that throws.
  Future<void> close() async {
    await connectivity.dispose();
    for (final box in boxes) {
      await box.close();
    }
  }

  Future<Box<dynamic>> open(String name) async {
    final box = await Hive.openBox<dynamic>(name);
    boxes.add(box);
    return box;
  }

  try {
    return await CoreRuntime.start(
      host: CoreHostBindings(
        secureStore: InMemorySecureKeyValueStore(),
        hiveBoxes: HiveBoxes(
          preferences: await open(HiveBoxNames.preferences),
          caches: await open(HiveBoxNames.caches),
          attachmentQueue: await open(HiveBoxNames.attachmentQueue),
          metadata: await open(HiveBoxNames.metadata),
        ),
        databaseOpener:
            databases ??
            _TestDatabases(Directory('${dataDir.path}/db'), interceptDatabase),
        worker: const DaemonWorkerPort(),
        connectivity: connectivity,
        reportNetwork: connectivity.report,
        overrides: <Override>[
          if (outboxDrainGate != null)
            outboxDrainGateProvider.overrideWithValue(outboxDrainGate),
        ],
        close: close,
        flushScheduler: flushScheduler,
        postFrameScheduler: postFrameScheduler,
        lifecycle: lifecycle,
      ),
      policy: const CoreHostPolicy(
        settingsDefaults: AppSettingsHostDefaults(
          sendOnEnter: true,
          notificationsEnabled: true,
        ),
        readAloudLiveDeviceSpeech: true,
      ),
    );
  } on Object {
    await close();
    rethrow;
  }
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
  _TestDatabases(this._directory, this._intercept);

  final Directory _directory;
  final QueryInterceptor? Function(String fileName)? _intercept;

  @override
  QueryExecutor open(String serverId) {
    _directory.createSync(recursive: true);
    final database = NativeDatabase.createInBackground(
      File('${_directory.path}/$serverId.sqlite'),
    );
    final interceptor = _intercept?.call(serverId);
    return interceptor == null
        ? database
        : database.interceptWith(interceptor);
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

/// The Open WebUI account database of [runtime], once it is signed in to a
/// fake server and the database is open.
Future<AppDatabase> signedInOpenWebUiDatabase(CoreRuntime runtime) async {
  final owui = await FakeOwuiAuthServer.start(
    users: const {
      'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
    },
  );
  addTearDown(owui.close);
  final accounts = AccountsService(runtime.container, events: EventBus());
  addTearDown(accounts.dispose);
  final auth = AuthService(runtime.container);
  addTearDown(auth.dispose);
  await accounts.add(
    AddAccount(server: ServerDraft(name: 'Lab', url: owui.url), force: true),
  );
  await auth.loginWithPassword(
    const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
  );
  final opened = Completer<AppDatabase>();
  final watch = runtime.container.listen<AppDatabase?>(appDatabaseProvider, (
    _,
    database,
  ) {
    if (database != null && !opened.isCompleted) opened.complete(database);
  }, fireImmediately: true);
  addTearDown(watch.close);
  final database = await opened.future;
  await database.customSelect('SELECT 1').get();
  return database;
}
