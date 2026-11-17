import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';

/// Set from the release tag, with the desktop app's version, by
/// .github/workflows/release-desktop.yml; the handshake reports it so a
/// mismatched pair is obvious in diagnostics.
const String daemonVersion = '0.1.0';

Future<void> main(List<String> args) async {
  // The whole daemon runs in one guarded zone: an asynchronous error
  // nothing handles is logged, and the daemon keeps serving. See
  // [runDaemonZone] for why a single zone also matters to shelf.
  final code = await runDaemonZone(
    () => _run(args),
    onStray: (error, stack) =>
        (_log ?? DaemonLog(level: 'error')).stray(error, stack),
  );
  // Exit explicitly instead of returning from main. A signed-in core keeps
  // sockets, sync timers and Riverpod subscriptions alive after the graceful
  // stop has finished, so the event loop never drains: the daemon used to log
  // "exited cleanly" and then run on, orphaned, after the app was gone.
  // `exit` drops unflushed output, so flush the two pipes first -- but not
  // for long: when the app is gone (it died, or quit the way a crash does)
  // the pipes have no reader and the flush never completes. A daemon with
  // nothing else alive still ended (its event loop drained), but a
  // signed-in one idled on there, orphaned, after logging "exited cleanly".
  await Future.wait<void>(<Future<void>>[stdout.flush(), stderr.flush()])
      .timeout(const Duration(seconds: 2), onTimeout: () => <void>[])
      .catchError((Object _) => <void>[]);
  exit(code);
}

/// The daemon's log once [_run] has made it; stray errors go there.
DaemonLog? _log;

/// Runs the daemon and answers the process exit code.
Future<int> _run(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'user-data',
      help:
          "The desktop app's userData directory. Everything the daemon "
          'writes lives beneath it.',
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
    return 64; // EX_USAGE
  }

  if (options.flag('help')) {
    stdout
      ..writeln('conduitd — the Conduit desktop sidecar')
      ..writeln()
      ..writeln(parser.usage);
    return 0;
  }
  if (options.flag('version')) {
    stdout.writeln(
      jsonEncode(<String, String>{
        'daemonVersion': daemonVersion,
        'protocolVersion': kConduitProtocolVersion,
      }),
    );
    return 0;
  }

  final log = _log = DaemonLog(level: options.option('log-level') ?? 'info');

  // stdin carries two signals on one subscription, because it can only be
  // listened to once: the bootstrap line, and then EOF meaning "the app is
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
    return 78; // EX_CONFIG
  }

  final directories = DaemonDirectories.create(
    options.option('user-data') ?? config.userDataDir,
  );
  // From here on every line also goes to userData/logs, which is what
  // `system.exportDiagnostics` zips, and the core's own records with it.
  // The bootstrap secrets are scrubbed from every line by value.
  log
    ..redactExactly(<String>[config.sessionToken, config.masterKey])
    ..attachFile(RotatingLogFile(Directory(directories.paths.logs)));
  DebugLogger.sink = DaemonLogSink(log);
  if (!installModelLogoCatalog()) {
    log.info('no model logo catalog; direct models show their initials');
  }

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
    await log.close();
    return 70; // EX_SOFTWARE
  }

  // The one line the app parses. Nothing else may ever reach stdout; that is
  // why DaemonLog writes to stderr.
  stdout.writeln(jsonEncode(<String, Object>{'ready': true, 'port': port}));
  await stdout.flush();

  // After the port is published, deliberately. The core reads a database and
  // a secure store off disk, and the app should not be kept waiting on that
  // before it can open a window -- `servers.*` and `auth.*` answer
  // `rpc.daemonUnavailable` for the short window in between.
  server.coreStarting();
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
    await log.close();
    return 77; // EX_NOPERM
  } on Object catch (error, stack) {
    log.error('failed to start the core', error, stack);
    await server.stop();
    await stdinSubscription.cancel();
    await log.close();
    return 70; // EX_SOFTWARE
  }

  // Every way of stopping takes the same path, `DaemonServer.requestStop`.
  final signals = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) => server.requestStop('SIGINT')),
    // SIGTERM cannot be watched on Windows; the app terminates the process
    // there instead.
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen(
        (_) => server.requestStop('SIGTERM'),
      ),
  ];

  // Closing stdin is how the app stops the daemon, and also what happens
  // when the app dies: either way nobody is left to serve. Without this the
  // daemon would outlive a crashed app and keep the user's sockets and sync
  // running with no window to show for it.
  unawaited(
    stdinClosed.future.then((_) {
      server.requestStop('stdin closed');
      // Nothing may keep the process once its app is gone (see the last
      // flush in [main]): a stop that has not ended the process in 10 s,
      // whatever it still waits on, is cut short.
      Timer(const Duration(seconds: 10), () {
        log.warn('still running 10 s after stdin closed: exiting now');
        exit(0);
      });
    }),
  );

  await server.onStopped;
  for (final signal in signals) {
    await signal.cancel();
  }
  await stdinSubscription.cancel();
  log.info('exited cleanly');
  await log.close();
  return 0;
}
