@TestOn('vm')
library;

import 'dart:io';

import 'package:conduit_core/database/database_provider.dart'
    show directLocalDatabaseProvider, kDirectLocalDatabaseFileName;
import 'package:conduit_core/persistence/hive_boxes.dart' show HiveBoxNames;
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduitd/conduitd.dart';
import 'package:drift/drift.dart' show QueryExecutor, QueryInterceptor;
import 'package:hive_ce/hive.dart';
import 'package:test/test.dart';

import '../../../packages/conduit_services/test/support/core.dart';
import 'support/null_sink.dart';
import 'support/runtime.dart' show testBootstrapConfig;

/// The daemon's stop when one of the core's databases fails to close: the
/// others and the host's stores still close, and the stop completes.
void main() {
  test('a database that fails to close stops nothing else: the others and '
      "the host's stores close, and the daemon stops", () async {
    addTearDown(PreferencesStore.debugReset);
    final temporary = Directory.systemTemp.createTempSync('runtime-dispose');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final runtime = await startTestCore(
      temporary,
      interceptDatabase: (fileName) =>
          fileName == kDirectLocalDatabaseFileName ? _CloseFails() : null,
    );
    addTearDown(runtime.dispose);
    final direct = runtime.container.read(directLocalDatabaseProvider);
    await direct.customSelect('SELECT 1').get();
    final account = await signedInOpenWebUiDatabase(runtime);
    final daemon = DaemonServer(
      config: testBootstrapConfig(temporary),
      directories: DaemonDirectories.create(temporary.path),
      daemonVersion: '0.0.0-test',
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    addTearDown(daemon.stop);
    await daemon.start();
    daemon.attachCore(runtime);

    await daemon.stop();
    await daemon.onStopped;
    await daemon.stop();
    await runtime.dispose();

    await expectLater(
      account.customSelect('SELECT 1').get(),
      throwsA(anything),
      reason: 'the account database was left open',
    );
    expect(Hive.isBoxOpen(HiveBoxNames.preferences), isFalse);
  });
}

/// Fails every close, as a database whose file went away would.
final class _CloseFails extends QueryInterceptor {
  @override
  Future<void> close(QueryExecutor inner) async {
    await inner.close();
    throw StateError('the database could not be closed');
  }
}
