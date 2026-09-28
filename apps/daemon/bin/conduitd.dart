import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';

/// Set from the release tag, with the Electron app's version, by
/// .github/workflows/release-desktop.yml; the handshake reports it so a
/// mismatched pair is obvious in diagnostics.
const String daemonVersion = '0.1.0';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'user-data',
      help:
          'Electron userData directory. Everything the daemon writes lives '
          'beneath it.',
    )
    ..addOption(
      'log-level',
      allowed: <String>['debug', 'info', 'warn', 'error'],
      defaultsTo: 'info',
    )
    ..addFlag(
      'version',
      negatable: false,
      help: 'Print the daemon and protocol versions and exit.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults options;
  try {
    options = parser.parse(args);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(parser.usage);
    exitCode = 64; // EX_USAGE
    return;
  }

  if (options.flag('help')) {
    stdout
      ..writeln('conduitd — the Conduit desktop sidecar')
      ..writeln()
      ..writeln(parser.usage);
    return;
  }
  if (options.flag('version')) {
    stdout.writeln(
      jsonEncode(<String, String>{
        'daemonVersion': daemonVersion,
        'protocolVersion': kConduitProtocolVersion,
      }),
    );
    return;
  }

  final log = DaemonLog(level: options.option('log-level') ?? 'info');

  // stdin carries two signals on one subscription, because it can only be
  // listened to once: the bootstrap line, and then EOF meaning "Electron is
  // gone". Splitting these across two `listen` calls throws at runtime.
  final firstLine = Completer<String>();
  final stdinClosed = Completer<void>();
  final stdinSubscription = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) {
          // Only the first line is bootstrap; the channel is not a protocol.
          if (!firstLine.isCompleted) firstLine.complete(line);
        },
        onDone: () {
          if (!firstLine.isCompleted) {
            firstLine.completeError(
              const FormatException('stdin closed before the bootstrap line'),
            );
          }
          if (!stdinClosed.isCompleted) stdinClosed.complete();
        },
        onError: (Object error) {
          if (!firstLine.isCompleted) firstLine.completeError(error);
        },
        cancelOnError: true,
      );

  // Secrets arrive here, never on argv or in the environment: both are
  // readable by any other process on every platform we ship to.
  final BootstrapConfig config;
  try {
    config = BootstrapConfig.parse(
      await firstLine.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () =>
            throw TimeoutException('no bootstrap line on stdin after 10s'),
      ),
    );
  } on Object catch (error) {
    log.error('bootstrap failed', error);
    await stdinSubscription.cancel();
    exitCode = 78; // EX_CONFIG
    return;
  }

  final directories = DaemonDirectories.create(
    options.option('user-data') ?? config.userDataDir,
  );

  final server = DaemonServer(
    config: config,
    directories: directories,
    daemonVersion: daemonVersion,
    log: log,
  );

  final int port;
  try {
    port = await server.start();
  } on Object catch (error, stack) {
    log.error('failed to bind loopback port', error, stack);
    await stdinSubscription.cancel();
    exitCode = 70; // EX_SOFTWARE
    return;
  }

  // The one line Electron parses. Nothing else may ever reach stdout; that is
  // why DaemonLog writes to stderr.
  stdout.writeln(jsonEncode(<String, Object>{'ready': true, 'port': port}));
  await stdout.flush();

  // After the port is published, deliberately. The core reads a database and
  // a secure store off disk, and Electron should not be kept waiting on that
  // before it can open a window -- `servers.*` and `auth.*` answer
  // `rpc.daemonUnavailable` for the short window in between.
  try {
    server.attachCore(
      await CoreRuntime.start(
        config: config,
        directories: directories,
        log: log,
      ),
    );
  } on SecureStoreCorruptException catch (error) {
    // The one startup failure that must not degrade quietly: continuing with
    // an empty store would show onboarding to a signed-in user and look like
    // their servers had vanished.
    log.error('secure store unreadable', error);
    await server.stop();
    await stdinSubscription.cancel();
    exitCode = 77; // EX_NOPERM
    return;
  } on Object catch (error, stack) {
    log.error('failed to start the core', error, stack);
    await server.stop();
    await stdinSubscription.cancel();
    exitCode = 70; // EX_SOFTWARE
    return;
  }

  final signals = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) => _requestStop(server, log)),
    // SIGTERM cannot be watched on Windows; Electron terminates the process
    // there instead.
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((_) => _requestStop(server, log)),
  ];

  // A closed stdin means the parent died. Without this the daemon would
  // outlive a crashed Electron and keep the user's sockets and sync running
  // with no window to show for it.
  unawaited(
    stdinClosed.future.then((_) {
      log.warn('stdin closed; parent process is gone');
      _requestStop(server, log);
    }),
  );

  await server.onStopped;
  for (final signal in signals) {
    await signal.cancel();
  }
  await stdinSubscription.cancel();
  log.info('exited cleanly');
}

void _requestStop(DaemonServer server, DaemonLog log) {
  log.info('stop requested');
  unawaited(server.stop());
}
