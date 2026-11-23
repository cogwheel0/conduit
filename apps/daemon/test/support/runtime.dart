import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduitd/conduitd.dart';

import 'null_sink.dart';

/// The core as the tests host it, over a data directory of the test's own.
///
/// A test that also runs a [DaemonServer] passes the [config],
/// [directories] and [log] it gave the server, so both share them.
Future<CoreRuntime> startTestRuntime(
  Directory dataDir, {
  BootstrapConfig? config,
  DaemonDirectories? directories,
  DaemonLog? log,
}) {
  // `PreferencesStore` is process-wide and keeps the first store it loads,
  // so without this a runtime would read and write the preferences of one
  // an earlier test, or file in the same isolate, started.
  PreferencesStore.debugReset();
  return CoreRuntime.start(
    config: config ?? testBootstrapConfig(dataDir),
    directories: directories ?? DaemonDirectories.create(dataDir.path),
    log: log ?? DaemonLog(level: 'error', sink: NullSink()),
  );
}

BootstrapConfig testBootstrapConfig(Directory dataDir) => BootstrapConfig(
  sessionToken: 'a' * 43,
  masterKey: base64.encode(List<int>.generate(32, (i) => i)),
  userDataDir: dataDir.path,
);
