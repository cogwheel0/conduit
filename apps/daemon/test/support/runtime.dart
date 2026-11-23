import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduitd/conduitd.dart';

export 'core.dart' show testDaemonPaths;

/// The core as the tests host it, over a data directory of the test's own,
/// with the desktop's stores and policy.
///
/// A test that also runs a [DaemonServer] passes the [config] and
/// [directories] it gave the server, so both share them.
Future<CoreRuntime> startTestRuntime(
  Directory dataDir, {
  BootstrapConfig? config,
  DaemonDirectories? directories,
}) async {
  // `PreferencesStore` is process-wide and keeps the first store it loads,
  // so without this a runtime would read and write the preferences of one
  // an earlier test, or file in the same isolate, started.
  PreferencesStore.debugReset();
  return CoreRuntime.start(
    host: await openDesktopCoreHost(
      config: config ?? testBootstrapConfig(dataDir),
      directories: directories ?? DaemonDirectories.create(dataDir.path),
    ),
    policy: desktopCorePolicy,
  );
}

BootstrapConfig testBootstrapConfig(Directory dataDir) => BootstrapConfig(
  sessionToken: 'a' * 43,
  masterKey: base64.encode(List<int>.generate(32, (i) => i)),
  userDataDir: dataDir.path,
);
