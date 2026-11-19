// Serves the daemon tests' fake Open Terminal, in its interactive mode, on a
// fixed port, for the desktop app's `--e2e terminal` pass. owui.sh start runs
// it next to the local Open WebUI and names it in TERMINAL_SERVER_CONNECTIONS
// (the "Build box" system terminal), with the key it is given here.
//
//   dart run tool/local_owui/fake_terminal.dart --port 8153 --key <key>
//
// Runs until it is sent SIGTERM or SIGINT.
import 'dart:async';
import 'dart:io';

import '../../apps/daemon/test/support/fake_terminal_server.dart';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final at = args.indexOf(name);
    return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
  }

  final port = int.tryParse(option('--port') ?? '');
  final key = option('--key');
  if (port == null || key == null || key.isEmpty) {
    stderr.writeln('usage: fake_terminal.dart --port <port> --key <key>');
    exit(64);
  }
  final terminal = await FakeTerminalServer.start(
    key: key,
    port: port,
    interactive: true,
  );
  stdout.writeln('fake terminal on ${terminal.url}');
  await Future.any(<Future<void>>[
    ProcessSignal.sigterm.watch().first,
    ProcessSignal.sigint.watch().first,
  ]);
  await terminal.close();
  // The other signal's subscription would keep the process alive.
  exit(0);
}
