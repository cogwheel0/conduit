@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/providers/host_ports.dart'
    show appLifecycleProvider;
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';
import 'support/runtime.dart';

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
final String _masterKey = base64.encode(List<int>.filled(32, 7));

/// A core that finishes starting after the daemon began to stop: what the
/// bin waits on before it exits covers it.
void main() {
  test('a core that arrives after the stop began is stopped, not '
      'served', () async {
    final dir = Directory.systemTemp.createTempSync('conduitd_late_core');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final config = BootstrapConfig(
      sessionToken: _token,
      masterKey: _masterKey,
      userDataDir: dir.path,
    );
    final directories = DaemonDirectories.create(dir.path);
    final stopping = DaemonServer(
      config: config,
      directories: directories,
      daemonVersion: '0.0.0-test',
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    stopping.coreStarting();
    final runtime = await startTestRuntime(
      dir,
      config: config,
      directories: directories,
    );
    var handedOver = false;
    addTearDown(() async {
      if (!handedOver) await runtime.dispose();
    });
    await stopping.stop();

    stopping.attachCore(runtime);
    handedOver = true;
    // What the bin waits on before it exits: by then the core has closed
    // its stores, so its folder can go at once.
    await stopping.onStopped;
    dir.deleteSync(recursive: true);
    await pumpEventQueue();

    expect(stopping.uiRequests, isNull, reason: 'no services were built');
    expect(
      () => runtime.container.read(appLifecycleProvider),
      throwsA(anything),
      reason: 'the core was disposed',
    );
  });
}
