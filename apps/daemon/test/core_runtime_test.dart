import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/connectivity_port.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/ports/worker_port.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduitd/src/bootstrap.dart';
import 'package:conduitd/src/core_runtime.dart';
import 'package:conduitd/src/daemon_paths.dart';
import 'package:conduitd/src/log.dart';
import 'package:conduitd/src/ports/database_opener.dart';
import 'package:conduitd/src/ports/secure_store.dart';
import 'package:conduitd/src/ports/worker.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

void main() {
  late Directory temporary;
  late CoreRuntime runtime;

  // One runtime for the group: `Hive.init` and `PreferencesStore` are both
  // process-global, so starting a second runtime in the same isolate would
  // be testing something the daemon never does (it starts exactly one).
  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('core-runtime-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
  });

  tearDownAll(() async {
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  test('the container binds the daemon host ports', () {
    final container = runtime.container;
    expect(container.read(databaseOpenerProvider), isA<DaemonDatabaseOpener>());
    expect(container.read(workerPortProvider), isA<DaemonWorkerPort>());
    expect(container.read(secureStorageProvider), isA<DaemonSecureStore>());
    expect(container.read(connectivityPortProvider), isA<ConnectivityPort>());
  });

  test('no port is left as the core default that must not be', () {
    // The in-memory secure store is the core's default and would lose every
    // credential on restart. Binding it is the mistake worth guarding.
    expect(
      runtime.container.read(secureStorageProvider),
      isNot(isA<InMemorySecureKeyValueStore>()),
    );
    expect(
      runtime.container.read(workerPortProvider),
      isNot(isA<InlineWorkerPort>()),
    );
  });

  test('PreferencesStore reads synchronously, as the core requires', () async {
    await PreferencesStore.put('daemon-test-key', 'value');
    expect(PreferencesStore.getString('daemon-test-key'), 'value');
  });

  test('the layout under userData is created', () {
    for (final name in <String>['db', 'cache', 'logs', 'staging', 'hive']) {
      expect(
        Directory('${temporary.path}/$name').existsSync(),
        isTrue,
        reason: '$name should exist',
      );
    }
    expect(File('${temporary.path}/preferences.json').existsSync(), isTrue);
  });

  test('the database opener resolves a real file path', () async {
    final opener = runtime.container.read(databaseOpenerProvider);
    final directory = await opener.databaseDirectory();
    expect(directory.path, '${temporary.path}/db');
  });

  test('secure values survive a restart of the store', () async {
    await runtime.container
        .read(secureStorageProvider)
        .write(key: 'token', value: 'persisted');

    final reopened = await DaemonSecureStore.open(
      file: File('${temporary.path}/secure_store.bin'),
      masterKey: base64.decode(base64.encode(List<int>.generate(32, (i) => i))),
    );
    expect(await reopened.read(key: 'token'), 'persisted');
  });
}
