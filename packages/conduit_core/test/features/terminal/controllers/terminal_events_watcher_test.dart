import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/terminal/controllers/terminal_events_watcher.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:test/test.dart';

import 'fake_events_channel.dart';

void main() {
  final uri = Uri.parse('wss://owui.test/api/v1/terminals/t1/events');
  const auth = <String, dynamic>{'type': 'auth', 'token': 'jwt'};

  late List<FakeEventsChannel> channels;
  late List<TerminalEvent> events;
  late List<Duration> delays;

  setUp(() {
    channels = [];
    events = [];
    delays = [];
  });

  TerminalEventsWatcher watcher({String? path = '/workspace/', bool ports = false}) {
    final watcher = TerminalEventsWatcher(
      openChannel: (opened, {required kind}) {
        check(opened).equals(uri);
        check(kind).equals(TerminalServerKind.system);
        final channel = FakeEventsChannel();
        channels.add(channel);
        return channel;
      },
      uri: uri,
      kind: TerminalServerKind.system,
      authPayload: auth,
      path: path,
      ports: ports,
      onEvent: events.add,
      retryDelay: (attempt) {
        final delay = Duration(milliseconds: 10 * (attempt + 1));
        delays.add(delay);
        return delay;
      },
    );
    addTearDown(watcher.stop);
    return watcher;
  }

  Future<void> settle([int milliseconds = 0]) async {
    await pumpEventQueue();
    if (milliseconds > 0) {
      await Future<void>.delayed(Duration(milliseconds: milliseconds));
      await pumpEventQueue();
    }
  }

  test('authenticates, then subscribes to the directory', () async {
    watcher().start();
    await settle();

    check(channels).length.equals(1);
    check(channels.single.decodedSent).deepEquals([
      auth,
      {'type': 'subscribe', 'path': '/workspace/'},
    ]);
  });

  test('a ports watcher subscribes to ports alone, and ignores paths', () async {
    final ports = watcher(path: null, ports: true)..start();
    await settle();
    ports.watchPath('/tmp/');
    await settle();

    check(channels.single.decodedSent).deepEquals([
      auth,
      {'type': 'subscribe', 'ports': true},
    ]);
  });

  test('reports file and port changes, ignoring other frames', () async {
    watcher().start();
    await settle();

    channels.single
      ..receive({'type': 'fs:ready'})
      ..receive({'type': 'fs:change'})
      ..receive({'type': 'something:new'})
      ..receive('not json')
      ..receive({
        'type': 'ports:change',
        'ports': [
          {'port': 5173, 'pid': 42, 'process': 'vite'},
          {'port': 0},
        ],
      });
    await settle();

    check(events).length.equals(3);
    check(events[0]).isA<TerminalFilesChanged>();
    check(events[1]).isA<TerminalFilesChanged>();
    final ports = (events[2] as TerminalPortsChanged).ports;
    check(ports).length.equals(1);
    check(ports.single.port).equals(5173);
    check(ports.single.pid).equals(42);
    check(ports.single.process).equals('vite');
  });

  test('a new directory replaces the subscription', () async {
    final subject = watcher()..start();
    // Before the socket is ready, the first subscription names it.
    subject.watchPath('/workspace/src/');
    await settle();
    final channel = channels.single;
    check(channel.decodedSent).deepEquals([
      auth,
      {'type': 'subscribe', 'path': '/workspace/src/'},
    ]);

    subject
      ..watchPath('/workspace/src/')
      ..watchPath('/tmp/');
    check(channel.decodedSent.skip(2)).deepEquals([
      {'type': 'subscribe', 'path': '/tmp/'},
    ]);
  });

  test('a socket that drops before its first event reconnects', () async {
    // A moment without network when the terminal opens.
    final subject = watcher()..start();
    await settle();

    channels.single.closeFromServer(1006);
    await settle(30);

    check(subject.active).isTrue();
    check(channels).length.equals(2);
    check(delays).deepEquals([const Duration(milliseconds: 10)]);
    check(channels.last.decodedSent).deepEquals([
      auth,
      {'type': 'subscribe', 'path': '/workspace/'},
    ]);
  });

  test('a failed handshake is tried again, waiting longer each time', () async {
    final subject = watcher()..start();
    channels.single.failHandshake();
    await settle(30);
    check(channels).length.equals(2);
    // The next try drops too, before answering.
    channels.last.closeFromServer(1006);
    await settle(40);

    check(subject.active).isTrue();
    check(channels).length.equals(3);
    check(delays).deepEquals([
      const Duration(milliseconds: 10),
      const Duration(milliseconds: 20),
    ]);
    check(channels.first.sent).isEmpty();
  });

  test('a terminal that cannot watch at all stops for good', () async {
    // Open Terminal closes with 1011 when it has no filesystem watcher or no
    // port discovery.
    final subject = watcher()..start();
    await settle();

    channels.single.closeFromServer(1011);
    await settle(50);

    check(subject.active).isFalse();
    check(channels).length.equals(1);
    check(delays).isEmpty();
  });

  test('a socket that cannot be made stops for good', () async {
    final subject = TerminalEventsWatcher(
      openChannel: (_, {required kind}) => throw ArgumentError('bad address'),
      uri: uri,
      kind: TerminalServerKind.system,
      authPayload: auth,
      path: '/workspace/',
      onEvent: events.add,
      retryDelay: (attempt) {
        delays.add(Duration.zero);
        return Duration.zero;
      },
    )..start();
    addTearDown(subject.stop);
    await settle(10);

    check(subject.active).isFalse();
    check(delays).isEmpty();
  });

  test('a deliberate close after data stops', () async {
    final subject = watcher()..start();
    await settle();
    channels.single
      ..receive({'type': 'fs:ready'})
      ..closeFromServer(4003);
    await settle(50);

    check(subject.active).isFalse();
    check(channels).length.equals(1);
    check(delays).isEmpty();
  });

  test('a dropped socket that worked reconnects to the latest path', () async {
    final subject = watcher()..start();
    await settle();
    channels.first
      ..receive({'type': 'fs:ready'})
      ..closeFromServer(1006);
    await settle();
    subject.watchPath('/workspace/docs/');

    await settle(30);

    check(subject.active).isTrue();
    check(channels).length.equals(2);
    check(delays).deepEquals([const Duration(milliseconds: 10)]);
    check(channels.last.decodedSent).deepEquals([
      auth,
      {'type': 'subscribe', 'path': '/workspace/docs/'},
    ]);

    // The server was heard from before, so a reconnect that drops before
    // answering backs off further instead of giving up.
    channels.last.closeFromServer(1011);
    await settle(40);
    check(channels).length.equals(3);
    check(delays).deepEquals([
      const Duration(milliseconds: 10),
      const Duration(milliseconds: 20),
    ]);
  });

  test('stop cancels a pending reconnect', () async {
    final subject = watcher()..start();
    await settle();
    channels.single
      ..receive({'type': 'fs:ready'})
      ..closeFromServer(1006);
    await settle();

    subject.stop();
    await settle(30);

    check(channels).length.equals(1);
    check(subject.active).isFalse();
  });

  test('stop closes an open socket and ignores what follows', () async {
    final subject = watcher()..start();
    await settle();

    subject.stop();
    await settle();

    check(channels.single.sinkClosed).isTrue();
    channels.single.receive({'type': 'fs:change'});
    await settle();
    check(events).isEmpty();
  });

  test('the default backoff doubles up to 30 seconds', () {
    check([
      for (var attempt = 0; attempt < 8; attempt++)
        terminalEventsRetryDelay(attempt).inSeconds,
    ]).deepEquals([1, 2, 4, 8, 16, 30, 30, 30]);
  });
}
