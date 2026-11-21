@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/app_database.dart' show AppDatabase;
import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider, openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show apiAuthTokenMirrorProvider, apiServiceProvider;
import 'package:conduit_core/sync/primary_sync_provider.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:drift/drift.dart' show Value;
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/null_sink.dart';

const _chatId = 'chat-shelf';

/// Disposing the runtime, or stopping the daemon, while Open WebUI sync work
/// is still out: the first pull after sign-in, the outbox drain a shutdown's
/// flush gave up on, or a pull the turns service waits for. The process
/// exits, or a test deletes the directory, once dispose returns: nothing may
/// write the account database after that, and a server that does not answer
/// must not hold it up.
void main() {
  test('dispose cuts off a pull the server holds, and nothing writes the '
      'account database after it', () async {
    final bench = await _Bench.start(holdChatReads: true);
    await bench.owui.chats.chatReadAsked.future;
    bench.recordWrites();

    await bench.dispose();
    final writtenAtDispose = List.of(bench.writes);
    bench.owui.chats.holdChatReads!.complete();
    await bench.firstPull;

    expect(
      bench.writes,
      writtenAtDispose,
      reason: 'a write came after dispose',
    );
  });

  test('dispose cuts off the drain a flush gave up on, and the outcome the '
      'drain records lands before dispose returns', () async {
    final bench = await _Bench.start();
    await bench.firstPull;
    final saved = bench.hold(bench.owui.chats.holdChatSaves = Completer());
    await bench.database.chatsDao.updateEnvelopeWithOutbox(
      _chatId,
      title: const Value('Shelf labels'),
      enqueue: true,
    );

    final pending = await bench.runtime.flushOutbox(budget: Duration.zero);
    await bench.owui.chats.chatSaveAsked.future;
    bench.recordWrites();
    await bench.dispose();
    final writtenAtDispose = List.of(bench.writes);
    saved.complete();

    expect(pending, 1);
    expect(
      writtenAtDispose,
      contains('outbox_ops'),
      reason: "the drain's outcome landed after dispose returned",
    );
  });

  // CodeRabbit 4651804323.
  test(
    'dispose cuts off a pull still out on a client a rebuild retired',
    () async {
      final bench = await _Bench.start(holdChatReads: true);
      await bench.owui.chats.chatReadAsked.future;
      final database = bench.database;
      final container = bench.runtime.container;
      // The session's client is rebuilt under the pull, which keeps the one it
      // was built with.
      final retired = container.read(apiServiceProvider);
      final token = container.read(apiAuthTokenMirrorProvider);
      container.read(apiAuthTokenMirrorProvider.notifier)
        ..set('$token-renewed')
        ..set(token);
      expect(identical(container.read(apiServiceProvider), retired), isFalse);
      final row = bench.owui.chats.stored[_chatId]!..['title'] = 'Shelf labels';
      row['updated_at'] = (row['updated_at'] as int) + 1;

      // The server answers the held read as soon as dispose is asked for.
      final disposed = bench.dispose();
      bench.owui.chats.holdChatReads!.complete();
      await disposed;

      expect(
        (await database.chatsDao.getChat(_chatId))?.title,
        isNot('Shelf labels'),
        reason: "the retired client's pull was answered: dispose waited on it",
      );
    },
  );

  test('stopping the daemon cuts off a pull the turns service waits for, '
      'rather than waiting for the server to answer it', () async {
    final bench = await _Bench.start(daemon: true);
    await bench.firstPull;
    final database = bench.database;
    final chats = bench.owui.chats;
    // A rating pulls its chat once it is done, and the turns service waits
    // for that pull as it is disposed. The rating's own read of the chat goes
    // through; the pull's is held, and the chat changes meanwhile.
    chats.chatReadsToPass = 1;
    final held = bench.hold(chats.holdChatReads = Completer());
    await expectLater(
      bench.rate('answer-gone'),
      throwsA(isA<json_rpc.RpcException>()),
    );
    await chats.chatReadAsked.future;
    final row = chats.stored[_chatId]!..['title'] = 'Shelf labels';
    row['updated_at'] = (row['updated_at'] as int) + 1;

    // The server answers the held read as soon as the stop is asked for.
    final stopped = bench.dispose();
    held.complete();
    await stopped;

    expect(
      (await database.chatsDao.getChat(_chatId))?.title,
      'Shelf',
      reason: "the held pull's answer was stored: stop waited on the server",
    );
  });
}

/// A runtime signed in to a fake Open WebUI server that keeps one chat, and
/// the first pull certification asks for, which reads it. With a [_daemon],
/// the runtime is its core, and [_window] is a window connected to it.
final class _Bench {
  _Bench._(this.runtime, this.owui, this._accounts, this._auth);

  final CoreRuntime runtime;
  final FakeOwuiAuthServer owui;
  final AccountsService _accounts;
  final AuthService _auth;
  DaemonServer? _daemon;
  json_rpc.Peer? _window;
  late final Future<Object?> firstPull;
  final List<String> writes = <String>[];
  late final AppDatabase database = runtime.container.read(
    appDatabaseProvider,
  )!;
  Future<void>? _disposing;

  static Future<_Bench> start({
    bool holdChatReads = false,
    bool daemon = false,
  }) async {
    // Each runtime reads its own preferences: the store is the process's.
    addTearDown(PreferencesStore.debugReset);
    final temporary = Directory.systemTemp.createTempSync('owui-dispose');
    addTearDown(() => temporary.deleteSync(recursive: true));
    final config = BootstrapConfig(
      sessionToken: 'a' * 43,
      masterKey: base64.encode(List<int>.generate(32, (i) => i)),
      userDataDir: temporary.path,
    );
    final directories = DaemonDirectories.create(temporary.path);
    final log = DaemonLog(level: 'error', sink: NullSink());
    final runtime = await CoreRuntime.start(
      config: config,
      directories: directories,
      log: log,
    );
    final owui =
        await FakeOwuiAuthServer.start(
            users: const {
              'ada@example.com': (
                id: 'user-ada',
                name: 'Ada',
                password: 'pw-ada',
              ),
            },
          )
          ..models = const ['kettle-model'];
    addTearDown(owui.close);
    owui.chats.seed(_chatId, userId: 'user-ada', title: 'Shelf');
    final events = EventBus();
    final accounts = AccountsService(runtime.container, events: events);
    final auth = AuthService(runtime.container);
    final bench = _Bench._(runtime, owui, accounts, auth);
    addTearDown(bench.dispose);
    if (daemon) await bench._attach(config, directories, log);
    if (holdChatReads) bench.hold(owui.chats.holdChatReads = Completer());

    // Certification asks for the first pull once it has opened the
    // database, later in the task that announces it: joining it from a
    // microtask joins that pull before it starts.
    final asked = Completer<void>();
    final certified = runtime.container.listen<Object?>(
      openWebUiCertifiedDatabaseServerProvider,
      (_, next) {
        if (next == null || asked.isCompleted) return;
        scheduleMicrotask(() {
          bench.firstPull = runtime.container
              .read(primarySyncProvider)
              .requestPull(reason: 'cache-refresh');
          asked.complete();
        });
      },
    );
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Lab', url: owui.url),
        force: true,
      ),
    );
    await auth.loginWithPassword(
      const PasswordLogin(username: 'ada@example.com', password: 'pw-ada'),
    );
    await asked.future;
    certified.close();
    return bench;
  }

  Future<void> _attach(
    BootstrapConfig config,
    DaemonDirectories directories,
    DaemonLog log,
  ) async {
    final daemon = _daemon = DaemonServer(
      config: config,
      directories: directories,
      daemonVersion: '0.0.0-test',
      log: log,
    );
    final port = await daemon.start();
    daemon.attachCore(runtime);
    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(config.sessionToken),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready;
    final window = _window = json_rpc.Peer(socket.cast<String>());
    unawaited(window.listen());
    addTearDown(window.close);
    await callTyped<HandshakeResponse>(
      window,
      ConduitMethods.systemHandshake,
      params: const HandshakeRequest(
        protocolVersion: kConduitProtocolVersion,
        clientName: 'test',
        clientVersion: '0.0.0',
        windowKind: WindowKind.headless,
        locale: 'en',
      ).toJson(),
      decodeResult: HandshakeResponse.fromJson,
    );
  }

  /// Rates [messageId] in the chat up, from the window.
  Future<Object?> rate(String messageId) => _window!.sendRequest(
    ConduitMethods.turnsRate,
    RateTurn(chatId: _chatId, messageId: messageId, rating: 1).toJson(),
  );

  /// Lets the server answer what [held] holds once the test ends, before
  /// the runtime is disposed.
  Completer<void> hold(Completer<void> held) {
    addTearDown(() {
      if (!held.isCompleted) held.complete();
    });
    return held;
  }

  /// Records the tables the account database writes from now on.
  void recordWrites() {
    final watch = database.tableUpdates().listen(
      (updates) => writes.addAll(updates.map((update) => update.table)),
    );
    addTearDown(watch.cancel);
  }

  /// Disposes the runtime, through the daemon's stop when it has one.
  Future<void> dispose() => _disposing ??= () {
    _accounts.dispose();
    _auth.dispose();
    return _daemon?.stop() ?? runtime.dispose();
  }();
}
