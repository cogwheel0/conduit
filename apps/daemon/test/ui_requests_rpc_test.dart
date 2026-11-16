@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

import 'support/null_sink.dart';

const String _token = 'cJkVQ1mEo3nT7pZs9YbXwF2gH5LdRaUvNi0KqMtBxCe';
final String _masterKey = base64.encode(List<int>.filled(32, 7));

/// A question from the core, across the RPC boundary and back.
///
/// One daemon for the file.
///
/// `Hive.init` and `PreferencesStore` are process-global, so a second
/// `CoreRuntime` in this isolate would not be a second daemon -- it would be
/// the same global storage under a new container, which is not a thing the
/// product ever does. Tests that need isolation use a distinct server id.
void main() {
  late Directory tempDir;
  late DaemonServer server;
  late int port;
  late json_rpc.Peer peer;
  final received = <EventEnvelope>[];

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('conduitd_ui_rpc');
    final config = BootstrapConfig(
      sessionToken: _token,
      masterKey: _masterKey,
      userDataDir: tempDir.path,
    );
    final directories = DaemonDirectories.create(tempDir.path);
    final log = DaemonLog(level: 'error', sink: NullSink());

    server = DaemonServer(
      config: config,
      directories: directories,
      daemonVersion: '0.0.0-test',
      log: log,
    );
    port = await server.start();
    server.attachCore(
      await CoreRuntime.start(
        config: config,
        directories: directories,
        log: log,
      ),
    );

    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(_token),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready;
    peer = json_rpc.Peer(socket.cast<String>());
    registerEventSink(peer, onEvent: received.add);
    unawaited(peer.listen());
    await callTyped<HandshakeResponse>(
      peer,
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
  });

  tearDownAll(() async {
    await peer.close();
    await server.stop();
    await tempDir.delete(recursive: true);
  });

  Future<UiRequest> nextRequest() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final hit = received
          .where((e) => e.event == ConduitEvents.uiRequest)
          .lastOrNull;
      if (hit != null) {
        received.remove(hit);
        return UiRequest.fromJson(hit.payload);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('no ui.request arrived');
  }

  test('a window hears the question and its answer reaches the core', () async {
    final answer = server.uiRequests!.confirm(
      title: 'Run delete_file?',
      message: 'a.txt',
    );
    final request = await nextRequest();
    expect(request.messageArgs['title'], 'Run delete_file?');

    final result = await peer.sendRequest(
      ConduitMethods.uiRespond,
      UiResponse(requestId: request.requestId, choice: 'allow').toJson(),
    );
    expect((result as Map)['accepted'], isTrue);
    expect(await answer, isTrue);

    // Settled for every window, so none keeps offering it.
    expect(
      received.any(
        (e) =>
            e.event == ConduitEvents.uiSettled &&
            e.payload['requestId'] == request.requestId,
      ),
      isTrue,
    );
  });

  test('a window that subscribes late is sent the waiting question under its '
      'own next number', () async {
    final answer = server.uiRequests!.confirm(title: 'Still there?');
    final request = await nextRequest();

    // A second window, opened after the question was asked.
    final socket = IOWebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port${ConduitHttpRoutes.rpc}'),
      protocols: buildSubprotocols(_token),
      headers: <String, dynamic>{'Origin': kConduitAppOrigin},
    );
    await socket.ready;
    final lateWindow = json_rpc.Peer(socket.cast<String>());
    addTearDown(lateWindow.close);
    final seenLate = <EventEnvelope>[];
    // The milestone: the settlement reaching this window, after the
    // replayed question.
    final settledHere = Completer<void>();
    final newsHere = Completer<void>();
    registerEventSink(
      lateWindow,
      onEvent: (envelope) {
        seenLate.add(envelope);
        if (!newsHere.isCompleted) newsHere.complete();
        if (envelope.event == ConduitEvents.uiSettled &&
            envelope.payload['requestId'] == request.requestId &&
            !settledHere.isCompleted) {
          settledHere.complete();
        }
      },
    );
    unawaited(lateWindow.listen());
    await callTyped<HandshakeResponse>(
      lateWindow,
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
    // The window is attached from its connection: session-wide news goes
    // to it before it subscribes, and numbers its events from there.
    server.events.emit(ConduitEventSpecs.syncStatus, const SyncState());
    await newsHere.future;
    await callTyped<EventSubscription>(
      lateWindow,
      ConduitMethods.eventsSubscribe,
      params: const EventSubscription().toJson(),
      decodeResult: EventSubscription.fromJson,
    );

    await peer.sendRequest(
      ConduitMethods.uiRespond,
      UiResponse(requestId: request.requestId, choice: 'deny').toJson(),
    );
    expect(await answer, isFalse);
    await settledHere.future;

    // The replayed question takes this window's next number after the
    // news it had, and the settlement follows: no gap, and no number
    // shared with another window.
    final mine = seenLate
        .where((e) => e.payload['requestId'] == request.requestId)
        .toList();
    expect(mine.map((e) => e.event).toList(), <String>[
      ConduitEvents.uiRequest,
      ConduitEvents.uiSettled,
    ]);
    expect(seenLate.map((e) => e.seq).toList(), <int>[
      for (var i = 1; i <= seenLate.length; i++) i,
    ]);
    final news = seenLate.indexWhere(
      (e) => e.event == ConduitEvents.syncStatus,
    );
    expect(news, isNonNegative);
    expect(seenLate.indexOf(mine.first), greaterThan(news));
  });

  test('a second answer to the same question is refused', () async {
    final answer = server.uiRequests!.confirm(title: 'Again?');
    final request = await nextRequest();
    await peer.sendRequest(
      ConduitMethods.uiRespond,
      UiResponse(requestId: request.requestId, choice: 'deny').toJson(),
    );
    final late = await peer.sendRequest(
      ConduitMethods.uiRespond,
      UiResponse(requestId: request.requestId, choice: 'allow').toJson(),
    );
    expect((late as Map)['accepted'], isFalse);
    expect(await answer, isFalse);
  });

  // Last: it closes the file's window. A window that drops without
  // closing is gone as surely as one that closed, and a question with no
  // timeout must not wait on it for ever.
  test(
    'when the last window drops, a waiting question takes its default',
    () async {
      final answer = server.uiRequests!.confirm(title: 'Still there?');
      await nextRequest();
      await peer.close();
      expect(await answer, isFalse);
    },
  );
}
