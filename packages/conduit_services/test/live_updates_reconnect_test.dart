@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/models/socket_transport_availability.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        socketServiceManagerProvider,
        socketServiceProvider,
        socketTransportOptionsProvider;
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:test/test.dart';

import 'support/core.dart';
import 'support/fake_owui_auth_server.dart';

/// Live updates (the Open WebUI socket) across a network outage, against a
/// fake Open WebUI that, as 0.13.4 does by default, serves its socket over
/// a websocket alone and answers every polling handshake 400. Stopped, the
/// server drops each connection unanswered, as a proxy or a forwarder in
/// front of it does while its way to the server is down.
void main() {
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late EventBus events;
  late AccountsService accounts;
  late AuthService auth;
  late DataService data;

  setUp(() async {
    final temporary = Directory.systemTemp.createTempSync('live-updates');
    addTearDown(() => temporary.deleteSync(recursive: true));
    runtime = await startTestCore(temporary);
    addTearDown(runtime.dispose);
    owui =
        await FakeOwuiAuthServer.start(
            users: const {
              'ada@example.com': (
                id: 'user-ada',
                name: 'Ada',
                password: 'pw-ada',
              ),
              'bob@example.com': (
                id: 'user-bob',
                name: 'Bob',
                password: 'pw-bob',
              ),
            },
          )
          ..models = const ['kettle-model'];
    addTearDown(owui.close);
    events = EventBus();
    accounts = AccountsService(runtime.container, events: events);
    addTearDown(accounts.dispose);
    auth = AuthService(runtime.container);
    addTearDown(auth.dispose);
    data = DataService(runtime.container, events: events);
    addTearDown(data.dispose);
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        force: true,
      ),
    );
    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
  });

  /// Completes once live updates are [connected] or not, as Settings › Data
  /// & Connection reads them: checked now, and at each socket health event.
  Future<void> liveUpdates({required bool connected}) {
    if (data.connection().connected == connected) return Future<void>.value();
    final done = Completer<void>();
    late final void Function() untap;
    untap = events.tap((event, _, _) {
      if (event != ConduitEvents.socketHealth ||
          done.isCompleted ||
          data.connection().connected != connected) {
        return;
      }
      done.complete();
      scheduleMicrotask(untap);
    });
    return done.future;
  }

  /// Completes once the server's config says it serves no polling, and the
  /// socket has been told.
  Future<void> serverPolicyRead() async {
    final read = Completer<void>();
    final watch = runtime.container.listen<SocketTransportAvailability>(
      socketTransportOptionsProvider,
      (_, next) {
        if (!next.allowPolling && !read.isCompleted) read.complete();
      },
      fireImmediately: true,
    );
    await read.future.whenComplete(watch.close);
    await runtime.container.read(socketServiceManagerProvider.future);
  }

  /// Reports the network [online] or not, as the window does, and completes
  /// once the core reads it so.
  Future<void> reportNetwork({required bool online}) {
    final read = Completer<void>();
    final watch = runtime.container.listen<bool>(isOnlineProvider, (_, next) {
      if (next == online && !read.isCompleted) read.complete();
    });
    runtime.reportNetwork(online: online);
    return read.future.whenComplete(watch.close);
  }

  /// Completes once the connection attempt the socket in use is making has
  /// failed, and the socket service has taken that in. A listener added with
  /// `on`, not `once`: the service may replace the socket as it takes the
  /// failure in, which clears that socket's `once` listeners first.
  Future<void> attemptFails() {
    final failed = Completer<void>();
    final socket = runtime.container.read(socketServiceProvider)!.socket!;
    socket.on('connect_error', (_) {
      if (!failed.isCompleted) failed.complete();
    });
    return failed.future;
  }

  test('a websocket-only server is never asked for a polling handshake: '
      'not while the way to it drops connections, nor once the network is '
      'back', () async {
    await liveUpdates(connected: true);
    final connected = runtime.container.read(socketServiceProvider);
    // A first sign-in has no config stored: it arrives once the socket is
    // up, which keeps its connection.
    await serverPolicyRead();
    expect(runtime.container.read(socketServiceProvider), same(connected));
    final chats = owui.chats;

    // The way to the server goes (the address released, a forwarder's
    // tunnel down) before the network's report says so, and a Retry meets
    // a dropped connection.
    chats.stopServer();
    await liveUpdates(connected: false);
    final retried = chats.nextSocketHandshakes(1);
    final retry = data.reconnect();
    final failed = attemptFails();
    expect(await retried, ['websocket']);
    await failed;

    await reportNetwork(online: false);
    chats.startServer();
    final back = chats.nextSocketHandshakes(1);
    await reportNetwork(online: true);
    expect(await back, ['websocket']);

    await liveUpdates(connected: true);
    expect((await retry).connected, isTrue);
    expect(chats.socketHandshakes, isNot(contains('polling')));
  });

  test('live updates the network report ended come back once the network '
      'is, after a try that met the server still out of reach', () async {
    await liveUpdates(connected: true);
    await serverPolicyRead();
    final chats = owui.chats;

    // The report comes first: the socket is closed here, by the core.
    await reportNetwork(online: false);
    await liveUpdates(connected: false);
    chats.stopServer();

    // The network is back before the way to the server is.
    final tried = chats.nextSocketHandshakes(1);
    await reportNetwork(online: true);
    final failed = attemptFails();
    expect(await tried, ['websocket']);
    await failed;

    chats.startServer();
    final health = await data.reconnect();
    expect(health.connected, isTrue);
    expect(health.transport, 'websocket');
    expect(chats.socketHandshakes, isNot(contains('polling')));
  });

  test('an account signed out of is not reconnected when the network comes '
      'back', () async {
    await liveUpdates(connected: true);
    final signedOut = runtime.container.read(socketServiceProvider)!;

    await accounts.signOut(const AccountSignOut());
    expect(runtime.container.read(socketServiceProvider), isNull);
    await reportNetwork(online: false);
    await reportNetwork(online: true);

    expect(runtime.container.read(socketServiceProvider), isNull);
    expect(signedOut.socket, isNull);
    expect(signedOut.isConnected, isFalse);
  });

  test('an account switched away from is not reconnected when the network '
      'comes back; the one in use is', () async {
    await liveUpdates(connected: true);
    final ada = runtime.container.read(socketServiceProvider)!;

    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        force: true,
      ),
    );
    await auth.loginWithPassword(
      const PasswordLogin(username: 'bob@example.com', password: 'pw-bob'),
    );
    final bob = await _replacement(runtime, ada);
    await liveUpdates(connected: true);

    await reportNetwork(online: false);
    await liveUpdates(connected: false);
    await reportNetwork(online: true);
    await liveUpdates(connected: true);

    expect(runtime.container.read(socketServiceProvider), same(bob));
    expect(bob.authToken, isNot(ada.authToken));
    expect(ada.socket, isNull);
    expect(ada.isConnected, isFalse);
  });
}

/// The socket service that replaces [previous] in [runtime].
Future<SocketService> _replacement(
  CoreRuntime runtime,
  SocketService previous,
) {
  final current = runtime.container.read(socketServiceProvider);
  if (current != null && !identical(current, previous)) {
    return Future<SocketService>.value(current);
  }
  final next = Completer<SocketService>();
  final watch = runtime.container.listen<SocketService?>(
    socketServiceProvider,
    (_, service) {
      if (service != null && !identical(service, previous)) {
        if (!next.isCompleted) next.complete(service);
      }
    },
  );
  return next.future.whenComplete(watch.close);
}
