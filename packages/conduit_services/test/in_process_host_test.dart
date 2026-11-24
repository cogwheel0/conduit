@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/read_aloud/device_speech_engine.dart'
    show DeviceSpeechEngine, NoDeviceSpeech;
import 'package:conduit_core/features/chat/read_aloud/tts_manager.dart';
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart'
    show voiceModeInputProvider;
import 'package:conduit_core/features/direct_connections/providers/apple_pcc_providers.dart'
    show applePccHostProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart'
    show DirectModelId;
import 'package:conduit_core/ports/ports.dart';
import 'package:conduit_core/providers/host_ports.dart'
    show cookieJarProvider, openExternalUrlProvider, uiRequestPortProvider;
import 'package:conduit_core/testing.dart' show FakeAppLifecycle;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as json_rpc;
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import 'support/core.dart';
import 'support/scripted_openai.dart';

/// The phone's in-process host over the app's own container, through an
/// in-memory duplex: sessions as strings, byte routes as frames, as a Swift
/// screen will reach it.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('in_process_host');
    addTearDown(() => temporary.deleteSync(recursive: true));
  });

  /// The app's core, in front, whose flushes wait for a frame that never
  /// comes, as with no Flutter view on screen: a protocol chat must stream
  /// without one.
  Future<void> startApp() async {
    runtime = await startTestCore(
      temporary,
      flushScheduler: const _NoFrames(),
      postFrameScheduler: const _NoFrames(),
      lifecycle: FakeAppLifecycle(),
    );
    addTearDown(runtime.dispose);
  }

  Future<(InProcessProtocolHost, _BytePeer)> startHost({
    MediaService? media,
    LocalTranscriber? transcriber,
    int limit = 64,
  }) async {
    final bytes = _BytePeer();
    final host = InProcessProtocolHost(
      container: runtime.container,
      system: SystemService(
        paths: testDaemonPaths,
        platform: 'ios',
        daemonVersion: '0.0.0-test',
        requestStop: (_) => fail('nothing stops this host'),
      ),
      window: await WindowPorts.open(),
      sendBytes: bytes.take,
      localTranscriber: transcriber,
      media: media,
      maxUnacknowledged: limit,
    );
    addTearDown(host.dispose);
    bytes.host = host;
    return (host, bytes);
  }

  _Client connect(InProcessProtocolHost host, String id) {
    final client = _Client(host, id);
    addTearDown(client.close);
    return client;
  }

  test('nothing is built before the first session, which handshakes; the '
      'namespaces the app keeps are not offered, and the chats are '
      'listed', () async {
    await startApp();
    final (host, _) = await startHost();
    check(host.services.isAttached).isFalse();

    final phone = connect(host, 'phone');
    check(host.services.isAttached).isTrue();
    final handshake = await phone.handshake();
    check(handshake.capabilities.notOffered).deepEquals(HostNamespace.values);
    await check(phone.ask(ConduitMethods.callsGet))
        .throws<json_rpc.RpcException>(
          (it) => it
              .has(RpcError.fromException, 'error')
              .has((e) => e.code, 'code')
              .equals(ConduitErrorCodes.unsupported),
        );
    final list = ChatList.fromJson(await phone.ask(ConduitMethods.chatsList));
    check(list.chats).isEmpty();
  });

  test('a turn streams to completion with no frame to come, and its chat is '
      'listed with the network down', () async {
    await startApp();
    final provider = await ScriptedOpenAi.start();
    addTearDown(provider.close);
    final saved = await DirectService(runtime.container).save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    final model = DirectModelId.encode(
      saved.connections.single.id,
      'scripted-model',
    );
    final (host, _) = await startHost();
    final phone = connect(host, 'phone');
    await phone.handshake();

    final accepted = SendTurnAccepted.fromJson(
      await phone.ask(
        ConduitMethods.turnsSend,
        SendTurn(model: model, text: 'hold:tide tables for Sunday').toJson(),
      ),
    );
    // Mid-answer, the parsed answer reaches the client too: the chat's own
    // state moves on without a frame.
    final parsed = phone.next(
      (e) => e.event == ConduitEvents.turnBlocks && e.scope == accepted.chatId,
    );
    final completed = phone.next(
      (e) =>
          e.event == ConduitEvents.turnCompleted && e.scope == accepted.chatId,
    );
    await phone.ask(
      ConduitMethods.eventsSubscribe,
      EventSubscription(scopes: <String>[accepted.chatId]).toJson(),
    );
    await parsed;
    provider.release('tide');
    final done = TurnCompleted.fromJson((await completed).payload);
    check(done.text).equals('tables for Sunday');
    check(done.messageId).equals(accepted.assistantMessageId);
    final deltas = [
      for (final e in phone.events)
        if (e.event == ConduitEvents.turnDelta) TurnDelta.fromJson(e.payload),
    ];
    check(deltas).isNotEmpty();
    check(deltas.last.text).isNotEmpty();
    phone.expectNumberedWithoutGaps();

    runtime.reportNetwork(online: false);
    final list = ChatList.fromJson(await phone.ask(ConduitMethods.chatsList));
    check(list.chats.map((c) => c.id)).contains(accepted.chatId);
  });

  test('two sessions at once each hear what is said, numbered from 1 '
      'without a gap, and one closing leaves the other serving', () async {
    await startApp();
    final (host, _) = await startHost();
    final first = connect(host, 'first');
    final second = connect(host, 'second');
    await first.handshake();
    await second.handshake();
    await first.ask(
      ConduitMethods.eventsSubscribe,
      const EventSubscription().toJson(),
    );
    await second.ask(
      ConduitMethods.eventsSubscribe,
      const EventSubscription().toJson(),
    );

    bool changed(EventEnvelope e) => e.event == ConduitEvents.settingsChanged;
    final heardFirst = first.next(changed);
    final heardSecond = second.next(changed);
    final settings = AppSettingsDto.fromJson(
      await first.ask(ConduitMethods.settingsGet),
    );
    await first.ask(
      ConduitMethods.settingsSet,
      AppSettingsPatch(sendOnEnter: !settings.sendOnEnter).toJson(),
    );
    await heardFirst;
    await heardSecond;
    first.expectNumberedWithoutGaps();
    second.expectNumberedWithoutGaps();

    await first.session.close();
    final list = ChatList.fromJson(await second.ask(ConduitMethods.chatsList));
    check(list.chats).isEmpty();
  });

  test("a client that falls behind gets each chat's latest streaming state "
      'and every other event, numbered without a gap', () async {
    await startApp();
    final (host, _) = await startHost(limit: 4);
    final phone = connect(host, 'phone');
    await phone.handshake();
    await phone.ask(
      ConduitMethods.eventsSubscribe,
      const EventSubscription(scopes: <String>['chat-a', 'chat-b']).toJson(),
    );

    final caughtUp = phone.next(
      (e) =>
          e.event == ConduitEvents.turnDelta &&
          e.scope == 'chat-b' &&
          e.payload['n'] == 41,
    );
    // The client stops taking messages: they arrive, but none is answered.
    phone.holdAcknowledgements();
    final events = host.services.events;
    final published = <String>[];
    // One frame at a time, as the turn pipeline emits them (it coalesces on
    // a timer): each one sent reaches the client before the next.
    Future<void> publish(String event, String? scope, int n) async {
      published.add('$event $scope $n');
      await phone.delivered(
        events,
        () => events.publish(
          event,
          scope: scope,
          payload: <String, dynamic>{'n': n},
        ),
      );
    }

    for (var n = 1; n <= 40; n++) {
      await publish(ConduitEvents.turnDelta, 'chat-a', n);
      if (n % 10 == 0) await publish(ConduitEvents.turnBlocks, 'chat-a', n);
      await publish(ConduitEvents.turnDelta, 'chat-b', n);
      if (n == 20) await publish(ConduitEvents.syncStatus, null, n);
    }
    // Chat a ends while the client is still behind; chat b streams on.
    await publish(ConduitEvents.turnCompleted, 'chat-a', 40);
    await publish(ConduitEvents.turnDelta, 'chat-b', 41);
    phone.releaseAcknowledgements();
    await caughtUp;

    final heard = [
      for (final e in phone.events) '${e.event} ${e.scope} ${e.payload['n']}',
    ];
    phone.expectNumberedWithoutGaps();
    // Only intermediate frames went missing, each for a later one.
    final missing = published.where((e) => !heard.contains(e)).toList();
    check(missing).isNotEmpty();
    check(missing).every(
      (e) => e.anyOf([
        (e) => e.startsWith('${ConduitEvents.turnDelta} '),
        (e) => e.startsWith('${ConduitEvents.turnBlocks} '),
      ]),
    );
    // In the order they were published.
    check(heard.where(published.contains).toList())
        .deepEquals(published.where(heard.contains));
    // Chat a's final state came before its completion.
    final completedAt = heard.indexOf(
      '${ConduitEvents.turnCompleted} chat-a 40',
    );
    check(heard.indexOf('${ConduitEvents.turnDelta} chat-a 40'))
      ..isGreaterOrEqual(0)
      ..isLessThan(completedAt);
    check(heard.indexOf('${ConduitEvents.turnBlocks} chat-a 40'))
      ..isGreaterOrEqual(0)
      ..isLessThan(completedAt);
    check(heard).contains('${ConduitEvents.syncStatus} null 20');
  });

  group('frames held for a client that falls behind', () {
    late InProcessProtocolHost host;
    late _Client phone;
    late EventBus events;

    Future<void> watch(
      List<String> scopes, {
      List<String> events = const <String>[],
    }) => phone.ask(
      ConduitMethods.eventsSubscribe,
      EventSubscription(events: events, scopes: scopes).toJson(),
    );

    setUp(() async {
      await startApp();
      (host, _) = await startHost(limit: 4);
      events = host.services.events;
      phone = connect(host, 'phone');
      await phone.handshake();
      await watch(<String>['chat-a', 'chat-b']);
    });

    // One frame per turn of the event loop, as the turn pipeline emits them.
    Future<void> publish(
      String event,
      String scope,
      String messageId,
      Object n,
    ) => phone.delivered(
      events,
      () => events.publish(
        event,
        scope: scope,
        payload: <String, dynamic>{
          'chatId': scope,
          'messageId': messageId,
          'n': n,
        },
      ),
    );

    /// What the client heard last of [messageId]'s answer, by event.
    Map<String, Object?> lastOf(String messageId) => <String, Object?>{
      for (final e in phone.events)
        if (e.payload['messageId'] == messageId) e.event: e.payload['n'],
    };

    /// Lets the client catch up, and waits until it has every message sent.
    Future<void> catchUp() async {
      final caughtUp = phone.next((e) => e.payload['n'] == 'caught up');
      phone.releaseAcknowledgements();
      await publish(ConduitEvents.syncStatus, 'chat-b', 'marker', 'caught up');
      await caughtUp;
    }

    test('each answer of a comparison keeps its own latest state', () async {
      phone.holdAcknowledgements();
      for (var n = 1; n <= 20; n++) {
        // The companion streams first, as `_emitCompanionDeltas` does, and
        // stops at 10; the main answer goes on.
        if (n <= 10) {
          await publish(ConduitEvents.turnDelta, 'chat-a', 'companion', n);
          await publish(ConduitEvents.turnBlocks, 'chat-a', 'companion', n);
        }
        await publish(ConduitEvents.turnDelta, 'chat-a', 'main', n);
        await publish(ConduitEvents.turnBlocks, 'chat-a', 'main', n);
      }
      await catchUp();
      check(lastOf('companion')).deepEquals(<String, Object?>{
        ConduitEvents.turnDelta: 10,
        ConduitEvents.turnBlocks: 10,
      });
      check(lastOf('main')).deepEquals(<String, Object?>{
        ConduitEvents.turnDelta: 20,
        ConduitEvents.turnBlocks: 20,
      });
      phone.expectNumberedWithoutGaps();
    });

    test('a catch-up sent straight to a client still behind comes after '
        'what was held for that answer', () async {
      phone.holdAcknowledgements();
      for (var n = 1; n <= 10; n++) {
        await publish(ConduitEvents.turnDelta, 'chat-a', 'main', n);
      }
      // What `TurnsService.catchUp` sends: past the filter, not asked.
      events.sendTo(
        'phone',
        ConduitEvents.turnCompleted,
        scope: 'chat-a',
        payload: <String, dynamic>{'messageId': 'main', 'n': 'done'},
      );
      await catchUp();
      final answer = [
        for (final e in phone.events)
          if (e.payload['messageId'] == 'main') e.payload['n'],
      ];
      check(answer.last).equals('done');
      check(answer.where((n) => n == 10)).length.equals(1);
      phone.expectNumberedWithoutGaps();
    });

    test('a chat the client stops watching while behind is owed nothing '
        'held: its catch-up when watched again is the last word', () async {
      phone.holdAcknowledgements();
      for (var n = 1; n <= 10; n++) {
        await publish(ConduitEvents.turnDelta, 'chat-a', 'main', n);
      }
      await watch(<String>['chat-b']);
      // The answer completes unwatched; watched again, its catch-up comes.
      await publish(ConduitEvents.turnCompleted, 'chat-a', 'main', 'done');
      await watch(<String>['chat-a', 'chat-b']);
      events.sendTo(
        'phone',
        ConduitEvents.turnCompleted,
        scope: 'chat-a',
        payload: <String, dynamic>{'messageId': 'main', 'n': 'caught up later'},
      );
      await catchUp();
      final answer = [
        for (final e in phone.events)
          if (e.payload['messageId'] == 'main') e.payload['n'],
      ];
      check(answer.last).equals('caught up later');
      check(answer).not((it) => it.contains(10));
      phone.expectNumberedWithoutGaps();
    });

    test('a chat remapped while frames are held gets them under its new id, '
        'and none under the old one after the remap', () async {
      await watch(<String>['local:tide', 'tide', 'chat-b']);
      phone.holdAcknowledgements();
      for (var n = 1; n <= 10; n++) {
        await publish(ConduitEvents.turnDelta, 'local:tide', 'main', n);
      }
      await phone.delivered(
        events,
        () => events.emit(
          ConduitEventSpecs.routeRemap,
          const RouteRemap(fromId: 'local:tide', toId: 'tide'),
        ),
      );
      await catchUp();
      final remappedAt = phone.events.indexWhere(
        (e) => e.event == ConduitEvents.routeRemap,
      );
      final after = phone.events.skip(remappedAt + 1);
      check(after.where((e) => e.scope == 'local:tide')).isEmpty();
      final last = after.lastWhere((e) => e.event == ConduitEvents.turnDelta);
      check(last.scope).equals('tide');
      check(last.payload['chatId']).equals('tide');
      check(last.payload['n']).equals(10);
    });

    group('several chats held', () {
      final chats = <String>[for (var c = 1; c <= 6; c++) 'chat-$c'];
      bool heardLast(String chat) =>
          phone.events.any((e) => e.scope == chat && e.payload['n'] == 5);

      setUp(() async {
        // Only what these tests publish reaches the client.
        await watch(
          chats,
          events: <String>[
            ConduitEvents.turnDelta,
            ConduitEvents.turnCompleted,
            ConduitEvents.syncStatus,
          ],
        );
        phone.queueAcknowledgements();
        for (var n = 1; n <= 5; n++) {
          for (final chat in chats) {
            await publish(ConduitEvents.turnDelta, chat, 'main', n);
          }
        }
        check(chats.where(heardLast)).isEmpty();
      });

      test('catching up, one acknowledgement lets one held frame go, so the '
          'client is never sent more than the limit', () async {
        check(phone.countInFlightFromHere()).equals(4);
        for (var round = 0; round < 3; round++) {
          final before = phone.events.length;
          final first = phone.next((_) => true);
          phone.acknowledgeOne();
          await first;
          // Never held, and sent after whatever that acknowledgement let go.
          final marked = phone.next((e) => e.event == ConduitEvents.syncStatus);
          events.publish(
            ConduitEvents.syncStatus,
            payload: <String, dynamic>{'n': 'marker $round'},
          );
          await marked;
          check(
            phone.events.length - before - 1,
            because: 'held frames one acknowledgement let go',
          ).equals(1);
          // The marker's own place in flight.
          phone.acknowledgeOne();
        }
        final rest = [
          for (final chat in chats)
            if (!heardLast(chat))
              phone.next((e) => e.scope == chat && e.payload['n'] == 5),
        ];
        phone.releaseAcknowledgements();
        await Future.wait(rest);
        phone.expectNumberedWithoutGaps();
      });

      test("each chat's final state goes before its completion, held or "
          'not', () async {
        for (final chat in chats) {
          await publish(ConduitEvents.turnCompleted, chat, 'main', 'done');
        }
        for (final chat in chats) {
          final answer = [
            for (final e in phone.events)
              if (e.scope == chat) e.payload['n'],
          ];
          check(
            answer.sublist(answer.length - 2),
            because: chat,
          ).deepEquals(<Object>[5, 'done']);
        }
        phone.expectNumberedWithoutGaps();
      });
    });

    test('a session whose transport fails a send is closed: nothing more '
        'goes on it, a call waiting on it settles, what was held is dropped, '
        'and a new session serves', () async {
      phone.holdAcknowledgements();
      for (var n = 1; n <= 10; n++) {
        await publish(ConduitEvents.turnDelta, 'chat-a', 'main', n);
      }
      // The reply to this call is the message that fails.
      phone.failNextSend = true;
      await check(phone.ask(ConduitMethods.chatsList)).throws<Object>();
      await phone.session.closed;
      phone.releaseAcknowledgements();
      await publish(ConduitEvents.turnDelta, 'chat-a', 'main', 11);
      check(phone.sentAfterFailure).equals(0);
      check(events.lastSeqFor('phone')).equals(0);

      final again = connect(host, 'phone-again');
      await again.handshake();
      await again.ask(
        ConduitMethods.eventsSubscribe,
        const EventSubscription(scopes: <String>['chat-a']).toJson(),
      );
      await again.delivered(
        events,
        () => events.publish(
          ConduitEvents.turnDelta,
          scope: 'chat-a',
          payload: <String, dynamic>{'messageId': 'main', 'n': 12},
        ),
      );
      check(again.events.map((e) => e.payload['n'])).deepEquals(<Object>[12]);
    });

    test('a session closed with frames held sends nothing more', () async {
      phone.holdAcknowledgements();
      for (var n = 1; n <= 10; n++) {
        await publish(ConduitEvents.turnDelta, 'chat-a', 'main', n);
      }
      await phone.session.close();
      // Off the bus: no path, a late acknowledgement's release included, can
      // send it anything.
      check(events.lastSeqFor('phone')).equals(0);
      check(events.wantedBy('phone', ConduitEvents.turnDelta, 'chat-a'))
          .isFalse();
    });
  });

  group('byte routes over frames', () {
    late HttpServer site;
    late Uint8List picture;
    late MediaService media;

    setUp(() async {
      // A picture on the account's own server, larger than three frames.
      picture = Uint8List(200 * 1024);
      for (var i = 0; i < picture.length; i++) {
        picture[i] = i % 251;
      }
      picture.setRange(0, 8, const <int>[137, 80, 78, 71, 13, 10, 26, 10]);
      site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => site.close(force: true));
      site.listen((request) {
        // A site that never answers.
        if (request.uri.path == '/never') return;
        request.response
          ..headers.contentType = ContentType('image', 'png')
          ..add(picture);
        unawaited(request.response.close());
      });
      media = MediaService(
        ownServer: () async => Uri.parse('http://127.0.0.1:${site.port}'),
      );
      addTearDown(media.close);
    });

    String pictureQuery() {
      final url = 'http://127.0.0.1:${site.port}/pier.png';
      return 'url=${Uri.encodeQueryComponent(url)}';
    }

    test('a download arrives in 64 KiB frames, whole', () async {
      await startApp();
      final (_, bytes) = await startHost(media: media);
      final answer = await bytes.request(
        1,
        'GET',
        '/media/image',
        query: pictureQuery(),
      );
      await answer.done;
      check(answer.status).equals(200);
      check(answer.headers['content-type']).equals('image/png');
      check(answer.chunks.map((c) => c.length))
          .deepEquals(<int>[65536, 65536, 65536, 200 * 1024 - 3 * 65536]);
      check(answer.body).deepEquals(picture);
    });

    test('a download the client abandons sends nothing more', () async {
      await startApp();
      final (_, bytes) = await startHost(media: media);
      // The client takes the first chunk and does not answer it yet.
      final firstChunk = bytes.holdAfter(1, ByteFrameKind.chunk);
      final answer = await bytes.request(
        1,
        'GET',
        '/media/image',
        query: pictureQuery(),
      );
      await firstChunk;
      // Taken at once, although the host still waits on the client's answer
      // to that chunk (a transport that answers only once this returns).
      await bytes.cancel(1);
      bytes.release();
      // The stream's last word: the host has let go, and still runs.
      await answer.settled;
      check(answer.error).equals('cancelled');
      check(answer.chunks).length.equals(1);
      check(answer.ended).isFalse();
    });

    test('an upload goes in 64 KiB frames, each chunk the route keeps is '
        'its own, and a cancelled one reaches no route', () async {
      await startApp();
      final transcriber = _Transcriber();
      final (host, bytes) = await startHost(transcriber: transcriber);
      final phone = connect(host, 'phone');
      await phone.handshake();
      await phone.ask(
        ConduitMethods.voiceSaveSettings,
        const VoiceSettingsEdit(localModel: 'tiny').toJson(),
      );

      final recording = Uint8List(150 * 1024);
      for (var i = 0; i < recording.length; i++) {
        recording[i] = (i * 7) % 256;
      }
      // The client sends every frame from one buffer it writes again for
      // the next: the host must have taken what it needs by then.
      final reused = Uint8List(ByteFrame.headerLength + ByteFrame.maxChunk);
      Future<void> sendFrom(ByteFrame frame) async {
        final encoded = frame.encode();
        reused.setRange(0, encoded.length, encoded);
        await host.receiveBytes(
          Uint8List.sublistView(reused, 0, encoded.length),
        );
        reused.fillRange(0, reused.length, 0xEE);
      }

      Future<void> open(int stream) => sendFrom(
        ByteFrame(
          stream,
          ByteFrameKind.open,
          payload: _json(<String, Object?>{
            'method': 'POST',
            'path': ConduitHttpRoutes.transcribe,
            'query': 'engine=local',
            'headers': <String, String>{'content-type': 'audio/wav'},
          }),
        ),
      );

      Future<_Answer> upload(int stream, Uint8List body) async {
        final answer = bytes.answerFor(stream);
        await open(stream);
        for (var at = 0; at < body.length; at += ByteFrame.maxChunk) {
          final end = at + ByteFrame.maxChunk < body.length
              ? at + ByteFrame.maxChunk
              : body.length;
          await sendFrom(
            ByteFrame(
              stream,
              ByteFrameKind.chunk,
              payload: Uint8List.sublistView(body, at, end),
            ),
          );
        }
        await sendFrom(ByteFrame(stream, ByteFrameKind.end));
        return answer;
      }

      final first = await upload(1, recording);
      await first.done;
      check(first.status).equals(200);
      check(transcriber.heard.single).deepEquals(recording);

      // One frame each: the route keeps the chunk it was handed as it is,
      // and the host never writes to it again.
      final short = Uint8List.fromList(List<int>.filled(1000, 1));
      final other = Uint8List.fromList(List<int>.filled(1000, 2));
      await (await upload(2, short)).done;
      await (await upload(3, other)).done;
      check(transcriber.heard[1]).deepEquals(short);
      check(transcriber.heard[2]).deepEquals(other);
      check(identical(transcriber.heard[1].buffer, transcriber.heard[2].buffer))
          .isFalse();

      // Abandoned after its first chunk: no route hears of it, and no answer
      // comes, only the stream's last word.
      final abandoned = bytes.answerFor(4);
      await open(4);
      await sendFrom(
        ByteFrame(4, ByteFrameKind.chunk, payload: Uint8List(1024)),
      );
      await bytes.cancel(4);
      // The next request is answered after it, on the same host.
      await (await upload(5, short)).done;
      await abandoned.settled;
      check(transcriber.heard).length.equals(4);
      check(abandoned.error).equals('cancelled');
      check(abandoned.status).isNull();
    });

    test('an answer given before the body ends tells the client to stop '
        'sending it', () async {
      await startApp();
      final (host, bytes) = await startHost();
      final answer = await bytes.request(
        1,
        'GET',
        ConduitHttpRoutes.transcribe,
        end: false,
      );
      await answer.done;
      check(answer.frames.first.kind).equals(ByteFrameKind.cancel);
      check(answer.status).equals(405);
      // A chunk sent anyway is taken, and goes nowhere.
      await host.receiveBytes(
        ByteFrame(1, ByteFrameKind.chunk, payload: Uint8List(8)).encode(),
      );
    });

    test(
      'a byte frame the client cannot take ends that stream alone',
      () async {
        await startApp();
        final (_, bytes) = await startHost(media: media);
        bytes.failFirst(1, ByteFrameKind.chunk);
        final first = await bytes.request(
          1,
          'GET',
          '/media/image',
          query: pictureQuery(),
        );
        final second = await bytes.request(
          2,
          'GET',
          '/media/image',
          query: pictureQuery(),
        );
        await second.done;
        check(second.body).deepEquals(picture);
        check(first.chunks).isEmpty();
        check(first.ended).isFalse();
      },
    );

    group('once its last frame is decided', () {
      late _BytePeer bytes;

      setUp(() async {
        await startApp();
        (_, bytes) = await startHost(media: media);
      });

      Future<_Answer> download(int stream) =>
          bytes.request(stream, 'GET', '/media/image', query: pictureQuery());

      test('a stream ends once: a cancel while its end is unacknowledged '
          'comes too late to change it', () async {
        final ending = bytes.holdAfter(1, ByteFrameKind.end);
        final first = await download(1);
        await ending;
        await bytes.cancel(1);
        bytes.release();
        // Served after it, on the same host.
        await (await download(2)).done;
        check(first.frames.last.kind).equals(ByteFrameKind.end);
        check(first.error).isNull();
      });

      test('its number is free: an open on it while its end is '
          'unacknowledged is a new request, and nothing of the old one '
          'follows', () async {
        final ending = bytes.holdAfter(1, ByteFrameKind.end);
        final first = await download(1);
        await ending;
        final again = bytes.renew(1);
        await download(1);
        bytes.release();
        await again.done;
        check(again.body).deepEquals(picture);
        check(again.error).isNull();
        check(first.frames.last.kind).equals(ByteFrameKind.end);
        check(first.error).isNull();
      });

      test('a stream that ends normally frees its number once: one used '
          'again before its end is acknowledged stays the live one, which a '
          'cancel reaches', () async {
        final ending = bytes.holdAfter(1, ByteFrameKind.end);
        final first = await download(1);
        await ending;
        final again = bytes.renew(1);
        final chunk = bytes.holdAfter(1, ByteFrameKind.chunk);
        await download(1);
        // The old end is taken: the old stream is done with, once.
        bytes.release();
        await chunk;
        await bytes.cancel(1);
        bytes.release();
        await again.settled;
        check(again.error).equals('cancelled');
        check(first.frames.where((f) => f.kind == ByteFrameKind.end)).length
            .equals(1);
        check(first.error).isNull();
      });

      test('its end failing to send after the number is used again touches '
          'only itself', () async {
        final ending = bytes.holdAfter(1, ByteFrameKind.end);
        await download(1);
        await ending;
        final again = bytes.renew(1);
        await download(1);
        bytes.release(fail: true);
        await again.done;
        check(again.body).deepEquals(picture);
      });
    });

    test('a cancel is taken at once, though its route is still answering '
        'and never finishes, and another stream is served meanwhile', () async {
      await startApp();
      final patient = MediaService(
        ownServer: () async => Uri.parse('http://127.0.0.1:${site.port}'),
        timeout: const Duration(hours: 1),
      );
      addTearDown(patient.close);
      final (_, bytes) = await startHost(media: patient);
      final url = 'http://127.0.0.1:${site.port}/never';
      final stuck = await bytes.request(
        1,
        'GET',
        '/media/image',
        query: 'url=${Uri.encodeQueryComponent(url)}',
      );
      await bytes.cancel(1);
      final other = await bytes.request(
        2,
        'GET',
        '/media/image',
        query: pictureQuery(),
      );
      await other.done;
      check(other.body).deepEquals(picture);
      check(stuck.frames).isEmpty();
    });

    group('a frame the host cannot take for a stream it can name', () {
      late InProcessProtocolHost host;
      late _BytePeer bytes;
      late _Transcriber transcriber;

      setUp(() async {
        await startApp();
        transcriber = _Transcriber();
        (host, bytes) = await startHost(transcriber: transcriber);
        final phone = connect(host, 'phone');
        await phone.handshake();
        await phone.ask(
          ConduitMethods.voiceSaveSettings,
          const VoiceSettingsEdit(localModel: 'tiny').toJson(),
        );
      });

      Future<_Answer> open(int stream) async {
        final answer = bytes.answerFor(stream);
        await host.receiveBytes(
          ByteFrame(
            stream,
            ByteFrameKind.open,
            payload: _json(<String, Object?>{
              'method': 'POST',
              'path': ConduitHttpRoutes.transcribe,
              'query': 'engine=local',
              'headers': <String, String>{'content-type': 'audio/wav'},
            }),
          ).encode(),
        );
        return answer;
      }

      Future<void> chunk(int stream, int byte, [int length = 1000]) =>
          host.receiveBytes(
            ByteFrame(
              stream,
              ByteFrameKind.chunk,
              payload: Uint8List.fromList(List<int>.filled(length, byte)),
            ).encode(),
          );

      Future<void> end(int stream) =>
          host.receiveBytes(ByteFrame(stream, ByteFrameKind.end).encode());

      test('an oversize chunk ends its stream with an error, so its body is '
          'never taken short, while an upload beside it completes', () async {
        final broken = await open(1);
        final beside = await open(2);
        await chunk(1, 1);
        await chunk(2, 2);
        // A chunk over 64 KiB, as a client that ignores the limit sends it.
        final oversize = Uint8List(
          ByteFrame.headerLength + ByteFrame.maxChunk + 1,
        );
        ByteData.sublistView(oversize)
          ..setUint32(0, 1)
          ..setUint8(4, ByteFrameKind.chunk.index)
          ..setUint32(8, ByteFrame.maxChunk + 1);
        await host.receiveBytes(oversize);
        await chunk(1, 3);
        await end(1);
        await end(2);
        await broken.settled;
        await beside.done;
        check(broken.error).isNotNull();
        check(broken.status).isNull();
        check(beside.status).equals(200);
        check(transcriber.heard).length.equals(1);
        check(transcriber.heard.single.toSet()).deepEquals(<int>{2});
      });

      test('a second open on a number still receiving its body ends it with '
          'an error', () async {
        final first = await open(1);
        await chunk(1, 1);
        await open(1);
        await end(1);
        await first.settled;
        check(first.error).isNotNull();
        check(first.status).isNull();
        check(transcriber.heard).isEmpty();
      });

      test('a chunk after the body ended, while the route still answers, '
          'ends the stream with an error instead of an answer', () async {
        final held = transcriber.hold = Completer<void>();
        final answer = await open(1);
        await chunk(1, 1);
        await end(1);
        await chunk(1, 2);
        held.complete();
        await answer.settled;
        check(answer.error).isNotNull();
        check(answer.status).isNull();
      });
    });

    test('every tunnel is refused: this host carries no socket', () async {
      await startApp();
      final (_, bytes) = await startHost();
      var stream = 0;
      for (final path in <String>['/terminal/anything', '/calls/anything']) {
        final answer = await bytes.request(++stream, 'GET', path);
        await answer.done;
        check(answer.status, because: path).equals(501);
      }
    });
  });

  test('disposed, the host leaves the app its container as it was: what the '
      'app installed, its ports, and nothing more said, even by a turn '
      'still answering', () async {
    await startApp();
    final provider = await ScriptedOpenAi.start();
    addTearDown(provider.close);
    final saved = await DirectService(runtime.container).save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    final model = DirectModelId.encode(
      saved.connections.single.id,
      'scripted-model',
    );
    final container = runtime.container;
    final previousPlayback = AudioPlaybackPort.hostFactory;
    final previousDevice = DeviceSpeechEngine.hostFactory;
    final previousClips = TtsManager.clipStore;
    addTearDown(() {
      AudioPlaybackPort.hostFactory = previousPlayback;
      DeviceSpeechEngine.hostFactory = previousDevice;
      TtsManager.clipStore = previousClips;
    });
    final AudioPlaybackPort Function() appPlayback = NullAudioPlayback.new;
    final DeviceSpeechEngine Function() appDevice = NoDeviceSpeech.new;
    final appClips = TemporaryFileClipStore();
    AudioPlaybackPort.hostFactory = appPlayback;
    DeviceSpeechEngine.hostFactory = appDevice;
    TtsManager.clipStore = appClips;
    final ports = <ProviderListenable<Object?>>[
      uiRequestPortProvider,
      openExternalUrlProvider,
      cookieJarProvider,
      voiceModeInputProvider,
      applePccHostProvider,
    ];
    final bound = <Object?>[for (final port in ports) container.read(port)];
    void expectAppKeepsItsOwn() {
      check(AudioPlaybackPort.hostFactory).identicalTo(appPlayback);
      check(DeviceSpeechEngine.hostFactory).identicalTo(appDevice);
      check(TtsManager.clipStore).identicalTo(appClips);
      for (var i = 0; i < ports.length; i++) {
        check(container.read(ports[i])).identicalTo(bound[i]);
      }
    }

    final (host, _) = await startHost();
    final phone = connect(host, 'phone');
    await phone.handshake();
    expectAppKeepsItsOwn();
    final asked = provider.asked('hold:tide');
    final accepted = SendTurnAccepted.fromJson(
      await phone.ask(
        ConduitMethods.turnsSend,
        SendTurn(model: model, text: 'hold:tide High water at noon').toJson(),
      ),
    );
    await phone.ask(
      ConduitMethods.eventsSubscribe,
      EventSubscription(scopes: <String>[accepted.chatId]).toJson(),
    );
    await asked;

    await host.dispose();
    phone.events.clear();
    // The answer still being written finishes, and the settings change.
    provider.release('tide');
    final settings = CoreSettingsService(container);
    await settings.set(
      AppSettingsPatch(sendOnEnter: !settings.get().sendOnEnter),
    );
    check(phone.events).isEmpty();
    expectAppKeepsItsOwn();

    // The container is the app's still: another host over it serves.
    final (again, _) = await startHost();
    final next = connect(again, 'next');
    await next.handshake();
    final list = ChatList.fromJson(await next.ask(ConduitMethods.chatsList));
    check(list.chats.map((c) => c.id)).contains(accepted.chatId);
  });

  test('a byte frame survives its own encoding, and a bad one, or a chunk '
      'over 64 KiB, is refused', () {
    final frame = ByteFrame(
      0xFEEDBEEF,
      ByteFrameKind.responseHead,
      flags: 3,
      payload: Uint8List.fromList(<int>[1, 2, 3]),
    );
    final decoded = ByteFrame.decode(frame.encode());
    check(decoded.stream).equals(0xFEEDBEEF);
    check(decoded.kind).equals(ByteFrameKind.responseHead);
    check(decoded.flags).equals(3);
    check(decoded.payload).deepEquals(<int>[1, 2, 3]);
    check(() => ByteFrame.decode(Uint8List(11))).throws<FormatException>();
    final wrongLength = frame.encode()..[11] = 9;
    check(() => ByteFrame.decode(wrongLength)).throws<FormatException>();
    final unknownKind = frame.encode()..[4] = 200;
    check(() => ByteFrame.decode(unknownKind)).throws<FormatException>();

    // A body chunk carries 64 KiB at most, either way.
    Uint8List chunkOf(int length) {
      final bytes = Uint8List(ByteFrame.headerLength + length);
      ByteData.sublistView(bytes)
        ..setUint8(4, ByteFrameKind.chunk.index)
        ..setUint32(8, length);
      return bytes;
    }

    check(ByteFrame.decode(chunkOf(ByteFrame.maxChunk)).payload).length
        .equals(ByteFrame.maxChunk);
    check(() => ByteFrame.decode(chunkOf(ByteFrame.maxChunk + 1)))
        .throws<FormatException>();
    check(
      () => ByteFrame(
        1,
        ByteFrameKind.chunk,
        payload: Uint8List(ByteFrame.maxChunk + 1),
      ).encode(),
    ).throws<StateError>();
  });
}

Uint8List _json(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// Frames that never come.
final class _NoFrames implements FlushScheduler, PostFrameScheduler {
  const _NoFrames();

  @override
  void scheduleFlush(void Function() callback) {}

  @override
  void runAfterCurrentFrame(void Function() callback) {}
}

/// A Swift screen's session, as strings both ways.
final class _Client {
  _Client(InProcessProtocolHost host, this.id) {
    final pipe = _pipe;
    session = host.open(
      id,
      send: (message) {
        if (failNextSend) {
          failNextSend = false;
          failed = true;
          throw StateError('the transport dropped a message');
        }
        if (failed) sentAfterFailure++;
        pipe.foreign.sink.add(message);
        // One at a time, events only: what the host holds back.
        if (_queue case final queue?
            when (jsonDecode(message) as Map)['method'] == kEventNotification) {
          final acknowledged = Completer<void>();
          queue.add(acknowledged);
          if (queue.length > maxInFlight) maxInFlight = queue.length;
          return acknowledged.future;
        }
        return _acknowledged?.future ?? Future<void>.value();
      },
    );
    pipe.foreign.stream.listen(session.receive);
    // The binding tells the client its session is gone: its side ends.
    unawaited(session.closed.then((_) => pipe.foreign.sink.close()));
    peer = json_rpc.Peer(pipe.local);
    registerEventSink(
      peer,
      onEvent: (envelope) {
        events.add(envelope);
        _heard.add(envelope);
      },
    );
    unawaited(peer.listen());
  }

  final StreamChannelController<String> _pipe = StreamChannelController<String>(
    sync: true,
  );
  final String id;
  late final InProcessSession session;
  late final json_rpc.Peer peer;
  final List<EventEnvelope> events = <EventEnvelope>[];
  final StreamController<EventEnvelope> _heard =
      StreamController<EventEnvelope>.broadcast(sync: true);
  Completer<void>? _acknowledged;

  /// Events taken and not yet acknowledged, one at a time
  /// ([acknowledgeOne]); anything else is acknowledged at once.
  List<Completer<void>>? _queue;
  int maxInFlight = 0;

  void queueAcknowledgements() => _queue = <Completer<void>>[];

  int get inFlight => _queue!.length;

  /// How many are in flight now, the most from here on.
  int countInFlightFromHere() => maxInFlight = _queue!.length;

  void acknowledgeOne() => _queue!.removeAt(0).complete();

  /// The next message the host hands over fails to send.
  bool failNextSend = false;
  bool failed = false;
  int sentAfterFailure = 0;

  /// Runs [publish] on [events], and waits until the client has what it was
  /// sent: nothing, when every event was held back.
  Future<void> delivered(EventBus events, void Function() publish) async {
    final before = events.lastSeqFor(id);
    publish();
    final sent = events.lastSeqFor(id);
    if (sent == before) return;
    if (this.events.isNotEmpty && this.events.last.seq >= sent) return;
    await _heard.stream.firstWhere((e) => e.seq >= sent);
  }

  /// The next event that passes [test], from now on.
  Future<EventEnvelope> next(bool Function(EventEnvelope) test) =>
      _heard.stream.firstWhere(test);

  void holdAcknowledgements() => _acknowledged = Completer<void>();

  void releaseAcknowledgements() {
    final held = _acknowledged;
    _acknowledged = null;
    held?.complete();
    final queue = _queue;
    _queue = null;
    for (final acknowledged in queue ?? const <Completer<void>>[]) {
      acknowledged.complete();
    }
  }

  Future<Map<String, dynamic>> ask(String method, [Object? params]) async =>
      (await peer.sendRequest(method, params) as Map).cast<String, dynamic>();

  Future<HandshakeResponse> handshake() async => HandshakeResponse.fromJson(
    await ask(
      ConduitMethods.systemHandshake,
      const HandshakeRequest(
        protocolVersion: kConduitProtocolVersion,
        clientName: 'test',
        clientVersion: '0.0.0',
        windowKind: WindowKind.main,
        locale: 'en',
      ).toJson(),
    ),
  );

  void expectNumberedWithoutGaps() {
    check(events.map((e) => e.seq))
        .deepEquals(List<int>.generate(events.length, (i) => i + 1));
  }

  Future<void> close() async {
    releaseAcknowledgements();
    await _pipe.foreign.sink.close();
    await peer.close();
    await _heard.close();
  }
}

/// One answer on the byte routes, as the client collects it.
final class _Answer {
  _Answer() {
    // Awaited where an answer is expected; an error frame is a result too.
    unawaited(_done.future.then<void>((_) {}, onError: (Object _) {}));
  }

  final List<ByteFrame> frames = <ByteFrame>[];
  final List<Uint8List> chunks = <Uint8List>[];
  final Completer<void> _done = Completer<void>();
  final Completer<void> _settled = Completer<void>();
  int? status;
  Map<String, String> headers = const <String, String>{};
  bool ended = false;

  /// What the host's error frame said, if it ended the stream with one.
  String? error;

  /// The answer's end; an error frame fails it.
  Future<void> get done => _done.future;

  /// The stream's last frame from the host, `end` or `error`: its number is
  /// free from then on.
  Future<void> get settled => _settled.future;

  Uint8List get body =>
      Uint8List.fromList([for (final chunk in chunks) ...chunk]);
}

/// The client's side of the byte routes.
final class _BytePeer {
  late InProcessProtocolHost host;
  final Map<int, _Answer> _answers = <int, _Answer>{};
  Completer<void>? _held;
  ({int stream, ByteFrameKind kind, Completer<void> seen})? _holdAfter;

  _Answer answerFor(int stream) => _answers.putIfAbsent(stream, _Answer.new);

  /// A new answer for [stream]'s number, used again: frames from now on
  /// are its.
  _Answer renew(int stream) => _answers[stream] = _Answer();

  ({int stream, ByteFrameKind kind})? _fail;

  /// The first [kind] frame of [stream] fails to send.
  void failFirst(int stream, ByteFrameKind kind) =>
      _fail = (stream: stream, kind: kind);

  /// Completes once a [kind] frame of [stream] arrives, which the client
  /// then does not answer until [release].
  Future<void> holdAfter(int stream, ByteFrameKind kind) {
    final seen = Completer<void>();
    _holdAfter = (stream: stream, kind: kind, seen: seen);
    return seen.future;
  }

  /// Answers the held frame: taken, or with [fail], not.
  void release({bool fail = false}) {
    final held = _held;
    _held = null;
    if (fail) {
      held?.completeError(StateError('the transport dropped a frame'));
    } else {
      held?.complete();
    }
  }

  Future<void> take(Uint8List bytes) async {
    final frame = ByteFrame.decode(bytes);
    final fail = _fail;
    if (fail != null &&
        fail.stream == frame.stream &&
        fail.kind == frame.kind) {
      _fail = null;
      throw StateError('the transport dropped a frame');
    }
    final answer = answerFor(frame.stream)..frames.add(frame);
    switch (frame.kind) {
      case ByteFrameKind.responseHead:
        final head = jsonDecode(utf8.decode(frame.payload)) as Map;
        answer
          ..status = head['status'] as int
          ..headers = (head['headers'] as Map).cast<String, String>();
      case ByteFrameKind.chunk:
        answer.chunks.add(Uint8List.fromList(frame.payload));
      case ByteFrameKind.end:
        answer.ended = true;
        answer._done.complete();
        answer._settled.complete();
      case ByteFrameKind.error:
        answer.error = utf8.decode(frame.payload);
        answer._done.completeError(answer.error!);
        answer._settled.complete();
      case ByteFrameKind.open || ByteFrameKind.cancel:
        break;
    }
    final hold = _holdAfter;
    if (hold != null &&
        hold.stream == frame.stream &&
        hold.kind == frame.kind) {
      _holdAfter = null;
      _held = Completer<void>();
      hold.seen.complete();
    }
    await _held?.future;
  }

  Future<_Answer> request(
    int stream,
    String method,
    String path, {
    String? query,
    Map<String, String> headers = const <String, String>{},
    bool end = true,
  }) async {
    final answer = answerFor(stream);
    await host.receiveBytes(
      ByteFrame(
        stream,
        ByteFrameKind.open,
        payload: _json(<String, Object?>{
          'method': method,
          'path': path,
          'query': ?query,
          'headers': headers,
        }),
      ).encode(),
    );
    if (end) {
      await host.receiveBytes(ByteFrame(stream, ByteFrameKind.end).encode());
    }
    return answer;
  }

  Future<void> cancel(int stream) =>
      host.receiveBytes(ByteFrame(stream, ByteFrameKind.cancel).encode());
}

/// Transcription on the device, which keeps what it was handed.
final class _Transcriber implements LocalTranscriber {
  final List<Uint8List> heard = <Uint8List>[];

  /// When set, a transcription waits for it.
  Completer<void>? hold;

  @override
  bool get available => true;

  @override
  List<LocalSpeechModel> get models => const <LocalSpeechModel>[
    LocalSpeechModel(id: 'tiny', name: 'Tiny', sizeBytes: 1),
  ];

  @override
  bool isDownloaded(String modelId) => true;

  @override
  int? receivedBytes(String modelId) => null;

  @override
  Future<void> download(
    String modelId, {
    required void Function() onProgress,
  }) async {}

  @override
  void delete(String modelId) {}

  @override
  void unload() {}

  @override
  Future<String> transcribe(
    String modelId,
    Uint8List wav, {
    String? language,
  }) async {
    await hold?.future;
    heard.add(wav);
    return '${wav.length} bytes';
  }
}
