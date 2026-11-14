// Smoke-tests a built conduitd the way the desktop app drives it.
//
//   dart run tool/smoke.dart build/cli/macos_arm64/bundle/bin/conduitd
//
// 1. `--version` prints the daemon and protocol versions as JSON.
// 2. Given a bootstrap line on stdin, it prints `{"ready":true,"port":N}`.
// 3. A client sending `Origin: app://conduit` and the session token can
//    open /rpc and complete `system.handshake`.
// 4. Closing stdin stops it, exit code 0, and its log file says so.
// 5. So does `system.shutdown`, a second run against the same user data,
//    with stdin left open.
// 6. Only when the local Open WebUI's env file exists (`tool/local_owui/
//    owui.sh up` writes it; test/live_server_test.dart reads the same one):
//    a third run signs in to that server, lists chats so sync starts, and
//    then closes stdin. A signed-in core holds sockets and timers open, and
//    the daemon must still exit.
// 7. Then, on the same user data, a fourth run with that server out of
//    reach: the third run signs in through a relay that is closed now. The
//    daemon must answer the account, its chats and its models from what it
//    stored, outlive the refreshes that fail behind them, and still stop
//    cleanly. A refresh like that used to end the process with 255.
//
// Exits non-zero on the first failure. CI runs it after `dart build cli`,
// with no local server, so step 6 is skipped there.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:web_socket_channel/io.dart';

import '../test/support/local_owui.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/smoke.dart <path to conduitd>');
    exit(64);
  }
  final binary = args.single;
  final userData = Directory.systemTemp.createTempSync('conduitd_smoke');
  // One pair for both runs: the second opens the secure store the first
  // wrote, which only the same master key can.
  final random = Random.secure();
  final token = base64Url
      .encode(List<int>.generate(48, (_) => random.nextInt(256)))
      .replaceAll('=', '');
  final masterKey = base64.encode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  final signedInData = Directory.systemTemp.createTempSync('conduitd_smoke');
  try {
    await _version(binary);
    for (final stopWithShutdown in <bool>[false, true]) {
      await _lifecycle(
        binary,
        userData,
        token: token,
        masterKey: masterKey,
        stopWithShutdown: stopWithShutdown,
      );
    }
    final credentials = _credentials();
    if (credentials == null) {
      stdout.writeln(
        'smoke: signed-in run skipped (no local Open WebUI env file)',
      );
    } else {
      // Its own user data: the earlier runs' store has no server in it, and
      // this run must not leave one behind for anyone else. Signed in
      // through a relay, so that closing the relay takes the server out of
      // reach for the next run.
      final relay = await _Relay.start(Uri.parse(credentials.url));
      try {
        await _lifecycle(
          binary,
          signedInData,
          token: token,
          masterKey: masterKey,
          stopWithShutdown: false,
          signIn: (
            url: relay.url,
            email: credentials.email,
            password: credentials.password,
          ),
        );
      } finally {
        await relay.close();
      }
      await _lifecycle(
        binary,
        signedInData,
        token: token,
        masterKey: masterKey,
        stopWithShutdown: false,
        offline: true,
      );
    }
    stdout.writeln('smoke: ok');
  } on _Failure catch (failure) {
    stderr.writeln('smoke: FAILED: ${failure.message}');
    exitCode = 1;
  } on Object catch (error, stack) {
    // A timeout, a bad frame or a dropped socket fails the smoke run too.
    stderr.writeln('smoke: FAILED: $error\n$stack');
    exitCode = 1;
  } finally {
    userData.deleteSync(recursive: true);
    signedInData.deleteSync(recursive: true);
  }
}

typedef _Credentials = ({String url, String email, String password});

/// The local Open WebUI to sign in to, or null to skip that run. Nothing
/// here prints a value.
_Credentials? _credentials() {
  final server = LocalOwui.read();
  if (server == null) return null;
  return (url: server.url, email: server.email, password: server.password);
}

/// Adds the account, signs in and lists chats, which is what a
/// window does on launch and what starts the core's sockets and sync.
Future<void> _signIn(json_rpc.Peer peer, _Credentials credentials) async {
  Map<String, dynamic> raw(Map<String, dynamic> json) => json;
  const timeout = Duration(seconds: 60);
  // Adding the account makes it the active one, signed out, for the
  // sign-in below.
  final added = await callTyped(
    peer,
    ConduitMethods.accountsAdd,
    params: AddAccount(
      server: ServerDraft(name: 'Smoke', url: credentials.url),
    ).toJson(),
    decodeResult: AccountChangeResult.fromJson,
  ).timeout(timeout);
  _check(
    added.accounts.activeAccountId != null,
    'accounts.add made the account active',
  );
  final snapshot = await callTyped(
    peer,
    ConduitMethods.authLoginWithPassword,
    params: PasswordLogin(
      username: credentials.email,
      password: credentials.password,
    ).toJson(),
    decodeResult: AuthSnapshot.fromJson,
  ).timeout(timeout);
  _check(
    snapshot.isAuthenticated,
    'sign-in failed (phase ${snapshot.phase}, code ${snapshot.errorCode})',
  );
  // Until the first sync has stored some, so the offline run has chats
  // to answer from.
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final chats = await callTyped(
      peer,
      ConduitMethods.chatsList,
      decodeResult: raw,
    ).timeout(timeout);
    if ((chats['chats'] as List).isNotEmpty) break;
    _check(DateTime.now().isBefore(deadline), 'no chats synced in 60 s');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  final models = await callTyped(
    peer,
    ConduitMethods.modelsList,
    decodeResult: ModelList.fromJson,
  ).timeout(timeout);
  _check(models.models.isNotEmpty, 'the server offers no models');
  stdout.writeln('smoke: signed in and listed chats and models');
}

/// The third run's account with its server out of reach. Everything the
/// app needs to open its main window comes from what the daemon stored.
Future<void> _offline(json_rpc.Peer peer) async {
  Map<String, dynamic> raw(Map<String, dynamic> json) => json;
  const timeout = Duration(seconds: 10);
  // The core reads its stores first; until then the session is loading.
  final settled = DateTime.now().add(timeout);
  AuthSnapshot auth;
  while (true) {
    auth = await callTyped(
      peer,
      ConduitMethods.authStatus,
      decodeResult: AuthSnapshot.fromJson,
    ).timeout(timeout);
    if (!auth.isLoading || DateTime.now().isAfter(settled)) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  _check(
    auth.isAuthenticated,
    'offline: auth.status is ${auth.phase}, not signed in',
  );
  final chats = await callTyped(
    peer,
    ConduitMethods.chatsList,
    decodeResult: raw,
  ).timeout(timeout);
  _check((chats['chats'] as List).isNotEmpty, 'offline: no stored chats');
  final models = await callTyped(
    peer,
    ConduitMethods.modelsList,
    decodeResult: ModelList.fromJson,
  ).timeout(timeout);
  _check(models.models.isNotEmpty, 'offline: no stored models');
  // The refreshes behind those answers fail meanwhile; the daemon has to
  // outlive them.
  await Future<void>.delayed(const Duration(seconds: 3));
  await callTyped(
    peer,
    ConduitMethods.systemPing,
    decodeResult: raw,
  ).timeout(timeout);
  stdout.writeln(
    'smoke: offline, answered from what it stored and kept serving',
  );
}

/// A TCP relay to [target], on a loopback port of its own: closing it is a
/// server that cannot be reached.
final class _Relay {
  _Relay._(this._server, this._target);

  final ServerSocket _server;
  final Uri _target;
  final List<Socket> _sockets = <Socket>[];

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<_Relay> start(Uri target) async {
    final relay = _Relay._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
      target,
    );
    relay._server.listen(relay._accept);
    return relay;
  }

  Future<void> _accept(Socket client) async {
    _sockets.add(client);
    try {
      final upstream = await Socket.connect(_target.host, _target.port);
      _sockets.add(upstream);
      unawaited(
        client.cast<List<int>>().pipe(upstream).catchError((Object _) {}),
      );
      unawaited(
        upstream.cast<List<int>>().pipe(client).catchError((Object _) {}),
      );
    } on Object {
      client.destroy();
    }
  }

  Future<void> close() async {
    await _server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }
}

Future<void> _version(String binary) async {
  final result = await Process.run(binary, <String>[
    '--version',
  ]).timeout(const Duration(seconds: 30));
  _check(result.exitCode == 0, '--version exited ${result.exitCode}');
  final version =
      jsonDecode((result.stdout as String).trim()) as Map<String, dynamic>;
  _check(
    version['protocolVersion'] == kConduitProtocolVersion,
    '--version reports protocol ${version['protocolVersion']}, '
    'expected $kConduitProtocolVersion',
  );
  final daemonVersion = version['daemonVersion'];
  _check(
    daemonVersion is String && daemonVersion.isNotEmpty,
    '--version reports no daemon version',
  );
  stdout.writeln('smoke: --version ${jsonEncode(version)}');
}

Future<void> _lifecycle(
  String binary,
  Directory userData, {
  required String token,
  required String masterKey,
  required bool stopWithShutdown,
  _Credentials? signIn,
  bool offline = false,
}) async {
  final process = await Process.start(binary, <String>[
    '--user-data',
    userData.path,
  ]);
  final stderrLines = <String>[];
  process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(stderrLines.add);
  // Read to the end, so the pipe never holds this script open; only the
  // first line is the ready line, and nothing may follow it.
  final stdoutLines = <String>[];
  final firstLine = Completer<String>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      stdoutLines.add(line);
      if (!firstLine.isCompleted) firstLine.complete(line);
    },
  );

  try {
    process.stdin.writeln(
      jsonEncode(<String, String>{
        'sessionToken': token,
        'masterKey': masterKey,
        'userDataDir': userData.path,
      }),
    );
    await process.stdin.flush();

    final line = await firstLine.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw _Failure('no ready line within 30 s'),
    );
    final ready = jsonDecode(line) as Map<String, dynamic>;
    _check(ready['ready'] == true && ready['port'] is int, 'bad ready line');
    final port = ready['port'] as int;
    stdout.writeln('smoke: ready on port $port');

    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(token),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready.timeout(const Duration(seconds: 10));
    final peer = json_rpc.Peer(socket.cast<String>());
    unawaited(peer.listen());
    final handshake = await callTyped<HandshakeResponse>(
      peer,
      ConduitMethods.systemHandshake,
      params: const HandshakeRequest(
        protocolVersion: kConduitProtocolVersion,
        clientName: 'smoke',
        clientVersion: '0.0.0',
        windowKind: WindowKind.headless,
        locale: 'en',
      ).toJson(),
      decodeResult: HandshakeResponse.fromJson,
    ).timeout(const Duration(seconds: 10));
    stdout.writeln(
      'smoke: handshake ok (needsOnboarding: ${handshake.needsOnboarding})',
    );
    if (signIn != null) await _signIn(peer, signIn);
    if (offline) await _offline(peer);
    final how = [
      if (signIn != null) 'signed in,',
      if (offline) 'offline,',
      stopWithShutdown ? 'system.shutdown' : 'stdin closed',
    ].join(' ');
    if (stopWithShutdown) {
      final result = await callTyped<ShutdownResult>(
        peer,
        ConduitMethods.systemShutdown,
        decodeResult: ShutdownResult.fromJson,
      ).timeout(const Duration(seconds: 10));
      _check(result.flushed, 'shutdown reports an unflushed outbox');
    } else {
      await peer.close();
      // The supported way to stop it.
      await process.stdin.close();
    }
    final code = await process.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw _Failure('still running 15 s after $how');
      },
    );
    if (stopWithShutdown) {
      await peer.close();
      await process.stdin.close().catchError((Object _) {});
    }
    _check(code == 0, 'exited $code after $how');
    _check(
      stdoutLines.length == 1,
      'stdout carried more than the ready line: ${stdoutLines.skip(1)}',
    );
    stdout.writeln('smoke: exited 0 after $how');

    final log = File('${userData.path}/logs/conduitd.log');
    _check(log.existsSync(), 'no log file at ${log.path}');
    final text = log.readAsStringSync();
    _check(text.contains('exited cleanly'), 'log does not end cleanly');
    _check(!text.contains(token), 'the session token reached the log');
  } on Object {
    // Whatever went wrong -- a check, a timeout, a dropped socket -- the
    // daemon goes, and what it said is shown.
    stderr.writeln(stderrLines.join('\n'));
    process.kill(ProcessSignal.sigkill);
    rethrow;
  }
}

void _check(bool condition, String message) {
  if (!condition) throw _Failure(message);
}

class _Failure implements Exception {
  _Failure(this.message);
  final String message;
}
