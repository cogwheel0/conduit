// Serves the daemon tests' fake Hermes Agent API server on a fixed port, for
// the desktop app's `--e2e hermes` pass. owui.sh start runs it next to the
// local Open WebUI, and seed.py writes its address and key to the env file.
//
//   dart run tool/local_owui/fake_hermes.dart --port 8152 --key <key>
//
// Runs until it is sent SIGTERM or SIGINT.
import 'dart:async';
import 'dart:io';

import '../../apps/daemon/test/support/fake_hermes_server.dart';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final port = int.tryParse(option('--port') ?? '');
  final key = option('--key');
  if (port == null || key == null || key.isEmpty) {
    stderr.writeln('usage: fake_hermes.dart --port <port> --key <key>');
    exit(64);
  }
  final hermes = await FakeHermesServer.start(key: key, port: port);
  stdout.writeln('fake Hermes on ${hermes.baseUrl}');
  await Future.any(<Future<void>>[
    ProcessSignal.sigterm.watch().first,
    ProcessSignal.sigint.watch().first,
  ]);
  await hermes.close();
  // The other signal's subscription would keep the process alive.
  exit(0);
}
