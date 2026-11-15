@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

import 'support/lines_sink.dart';

/// A provider that fails after it has answered, as the core's model list
/// does: it answers from a cache, then the refresh behind it cannot reach
/// the server. It also drops a future that fails, with nothing to catch it.
final class _Refreshing extends AsyncNotifier<int> {
  @override
  Future<int> build() async {
    Future<void>.microtask(() async {
      state = await AsyncValue.guard<int>(
        () async => throw const SocketException('No route to host'),
      );
    });
    unawaited(_dropped());
    return 1;
  }

  Future<void> _dropped() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    throw StateError('a refresh nobody awaited');
  }
}

final _refreshing = AsyncNotifierProvider<_Refreshing, int>(_Refreshing.new);

/// The daemon in miniature, in an isolate of its own so that dying is
/// something the test can watch: the core's container, and a shelf server
/// whose handler awaits the provider, as `models.list` did. Reports each
/// status the handler answered, then 'done'.
Future<void> _daemon(List<Object> args) async {
  final report = args[0] as SendPort;
  final guarded = args[1] as bool;

  Future<int> body() async {
    final container = ProviderContainer();
    container.listen(_refreshing, (_, _) {});
    await container.read(_refreshing.future);
    // Let the refresh fail first.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final server = await shelf_io.serve(
      (shelf.Request request) async {
        try {
          await container.read(_refreshing.future);
          return shelf.Response.ok('ok');
        } on Object {
          return shelf.Response(503);
        }
      },
      InternetAddress.loopbackIPv4,
      0,
    );
    final client = HttpClient();
    for (var i = 0; i < 2; i++) {
      final request = await client.get('127.0.0.1', server.port, '/');
      final response = await request.close();
      await response.drain<void>();
      report.send(response.statusCode);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    client.close(force: true);
    await server.close(force: true);
    container.dispose();
    return 0;
  }

  if (guarded) {
    await runDaemonZone(
      body,
      onStray: (error, _) => report.send('stray: $error'),
    );
  } else {
    await body();
  }
  report.send('done');
}

/// Runs [_daemon] and collects what it reports, and the error it died of.
Future<({List<Object?> reports, Object? died})> _run({
  required bool guarded,
}) async {
  final reports = <Object?>[];
  final messages = ReceivePort();
  final errors = ReceivePort();
  final exits = ReceivePort();
  Object? died;
  messages.listen(reports.add);
  errors.listen((error) => died ??= (error as List<Object?>).first);
  await Isolate.spawn(
    _daemon,
    <Object>[messages.sendPort, guarded],
    onError: errors.sendPort,
    onExit: exits.sendPort,
  );
  await exits.first.timeout(const Duration(seconds: 20));
  // Let the last messages arrive.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  messages.close();
  errors.close();
  return (reports: reports, died: died);
}

void main() {
  test('outside the daemon zone, a provider error a request handler awaits '
      'ends the process', () async {
    final run = await _run(guarded: false);
    // shelf put the handler in a zone of its own; the failed future
    // belonged to the root zone; the error could not cross, and was
    // uncaught there.
    expect(run.died, isNotNull);
    expect(run.reports, isNot(contains('done')));
  });

  test('in the daemon zone, the handler receives the error, a stray error '
      'is reported, and the daemon keeps serving', () async {
    final run = await _run(guarded: true);
    expect(run.died, isNull);
    expect(run.reports.whereType<int>(), <int>[503, 503]);
    expect(
      run.reports.whereType<String>(),
      containsAllInOrder(<Matcher>[
        contains('stray: Bad state: a refresh nobody awaited'),
        equals('done'),
      ]),
    );
    // Only the dropped future is stray: the handler got its own error.
    expect(
      run.reports.whereType<String>().where((r) => r.startsWith('stray')),
      hasLength(1),
    );
  });

  test('a stray error goes to the log with its stack, scrubbed', () {
    final sink = LinesSink();
    final lines = sink.lines;
    final log = DaemonLog(level: 'error', sink: sink)
      ..redactExactly(<String>['s' * 20]);
    log.stray(
      StateError('token=${'s' * 20}'),
      StackTrace.fromString('#0      main (file:///daemon.dart:1)\n'),
    );
    expect(lines.first, contains('unhandled async error, still serving'));
    expect(lines.join('\n'), isNot(contains('s' * 20)));
    expect(lines.last, contains('main (file:///daemon.dart:1)'));
  });
}
