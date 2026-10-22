import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_group_live_reply.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _Channel extends Mock implements WebSocketChannel {}

class _Sink extends Mock implements WebSocketSink {}

class _Rest implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions request,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async => ResponseBody.fromString(
    jsonEncode({'auth_required': false, 'desktop_gateway': true}),
    200,
    headers: {
      Headers.contentTypeHeader: ['application/json'],
    },
  );
  @override
  void close({bool force = false}) {}
}

void main() {
  late HermesDesktopApiService service;
  late HermesDesktopRpcClient rpc;
  late StreamController<Object?> input;
  late List<Map<String, dynamic>> calls;
  var truncated = false, coding = false, wrongSource = false;
  var snapshot = 'Hel';
  Map<String, dynamic> event(
    String type,
    int seq, [
    Map<String, dynamic> payload = const {},
  ]) => {
    'type': type,
    'session_id': 'runtime-r',
    'seq': seq,
    'payload': payload,
  };
  void push(String type, int seq, [Map<String, dynamic> payload = const {}]) =>
      input.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': event(type, seq, payload),
        }),
      );
  const group = HermesBotGroup(
    key: 'id:team',
    roomId: 'team',
    name: 'Team',
    memberProfiles: ['research', 'coding'],
    coordinator: 'research',
    raw: {'hosted': true},
  );
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      done(),
      true,
      reason: 'Expected incremental output before any completion frame',
    );
  }

  setUp(() async {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    truncated = false;
    snapshot = 'Hel';
    calls = [];
    input = StreamController<Object?>.broadcast();
    coding = wrongSource = false;
    final channel = _Channel(), sink = _Sink();
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(() {
        if (!input.isClosed) {
          input.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {'type': 'gateway.ready', 'payload': {}},
            }),
          );
        }
      });
      return input.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final call = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      calls.add(call);
      if (call['id'] == null) return;
      final params = call['params'] as Map? ?? {};
      final Object result = switch (call['method']) {
        'session.list' => {
          'sessions': [
            if (params['profile'] == 'research' || coding)
              {
                'id': params['profile'] == 'coding' ? 'stored-c' : 'stored-r',
                'title': 'Group: team',
                'source': wrongSource ? 'telegram' : 'bot_room',
              },
          ],
        },
        'session.resume' => {
          'session_id': params['profile'] == 'coding'
              ? 'runtime-c'
              : 'runtime-r',
          'session_key': params['profile'] == 'coding'
              ? 'stored-c'
              : 'stored-r',
          'running': true,
          'inflight': {
            'assistant': params['profile'] == 'coding' ? 'Code' : snapshot,
            'streaming': true,
            'user': 'A group prompt',
          },
          'turn_started_at': 1234,
        },
        'session.events.since' => {
          'events': truncated
              ? [
                  event('message.delta', 42, {'delta': 'should not duplicate'}),
                ]
              : [
                  event('message.start', 1),
                  event('message.delta', 2, {'delta': 'Hel'}),
                ],
          'latest_seq': truncated ? 42 : 2,
          'epoch': 'fixture',
          'truncated': truncated,
        },
        _ => {},
      };
      if (call['method'] == 'session.events.since' &&
          params['profile'] == 'coding') {
        final replay = result as Map;
        replay['events'] = [
          {...event('message.start', 1), 'session_id': 'runtime-c'},
          {
            ...event('message.delta', 2, {'delta': 'Code'}),
            'session_id': 'runtime-c',
          },
        ];
      }
      input.add(
        jsonEncode({'jsonrpc': '2.0', 'id': call['id'], 'result': result}),
      );
    });
    rpc = HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => channel,
    );
    final connect = rpc.connect(Uri.parse('ws://fixture.invalid/api/ws'));
    input.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': {}},
      }),
    );
    await connect;
    service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'http://fixture.invalid',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(
          legacyToken: 'fixture-token',
        ),
      ),
      rpc: rpc,
      dio: Dio()..httpClientAdapter = _Rest(),
    );
  });
  tearDown(() async {
    service.close();
    await rpc.close();
    await input.close();
    PreferencesStore.debugReset();
  });

  test('hosted replies deliver token deltas before the member finishes without submitting a prompt', () async {
    final seen = <HermesGroupLiveReply>[];
    final subscription = service.watchGroupReplies(group).listen(seen.add);
    addTearDown(subscription.cancel);
    await until(() => seen.any((r) => r.text == 'Hel'));
    push('message.delta', 3, {'delta': 'lo'});
    await until(() => seen.last.text == 'Hello');
    expect(seen.last.complete, false);
    expect(seen.last.profile, 'research');
    expect(
      calls.where(
        (c) =>
            c['method'] == 'prompt.submit' ||
            c['method'] == 'groups.send' ||
            c['method'] == 'session.create',
      ),
      isEmpty,
    );
    final scoped =
        calls.where((c) => c['method'] == 'session.resume').single['params']
            as Map;
    expect(scoped['profile'], 'research');
    expect(scoped['session_id'], 'stored-r');
    expect(scoped['lazy'], true);
    expect(scoped['omit_messages'], true);
  });

  test(
    'replayed and duplicate frames never repeat text or leak another session',
    () async {
      final seen = <HermesGroupLiveReply>[];
      final sub = service.watchGroupReplies(group).listen(seen.add);
      addTearDown(sub.cancel);
      await until(() => seen.isNotEmpty);
      push('message.delta', 2, {'delta': 'Hel'});
      input.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            ...event('message.delta', 3, {'delta': 'Wrong conversation'}),
            'session_id': 'unrelated',
          },
        }),
      );
      push('message.delta', 3, {'delta': 'lo'});
      push('message.delta', 3, {'delta': 'lo'});
      await until(() => seen.last.text == 'Hello');
      push('message.complete', 4, {'content': 'Hello world'});
      await until(() => seen.last.complete);
      expect(seen.last.text, 'Hello world');
      await sub.cancel();
      expect(
        calls.where(
          (c) => const [
            'session.close',
            'session.interrupt',
            'groups.stop',
          ].contains(c['method']),
        ),
        isEmpty,
      );
      expect(rpc.isReady, true);
    },
  );

  test('a replay gap restores the real in-flight snapshot instead of appending an overlapping tail', () async {
    truncated = true;
    snapshot = 'A complete prefix';
    final seen = <HermesGroupLiveReply>[];
    final sub = service.watchGroupReplies(group).listen(seen.add);
    addTearDown(sub.cancel);
    await until(() => seen.isNotEmpty);
    expect(seen.last.text, 'A complete prefix');
    snapshot = 'A complete prefix continues';
    await until(() => seen.last.text == snapshot);
    expect(seen.every((r) => !r.text.contains('should not duplicate')), true);
  });
  test(
    'different group members keep separate live text and identities',
    () async {
      coding = true;
      final seen = <HermesGroupLiveReply>[];
      final sub = service.watchGroupReplies(group).listen(seen.add);
      addTearDown(sub.cancel);
      await until(() => seen.map((r) => r.profile).toSet().length == 2);
      input.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            ...event('message.delta', 3, {'delta': ' reply'}),
            'session_id': 'runtime-c',
          },
        }),
      );
      await until(
        () => seen.last.profile == 'coding' && seen.last.text == 'Code reply',
      );
      expect(seen.lastWhere((r) => r.profile == 'research').text, 'Hel');
    },
  );
  test(
    'a normal chat with the same title is never attached as a group session',
    () async {
      wrongSource = true;
      final seen = <HermesGroupLiveReply>[];
      final sub = service.watchGroupReplies(group).listen(seen.add);
      addTearDown(sub.cancel);
      await until(() => calls.any((c) => c['method'] == 'session.list'));
      push('message.delta', 10, {'delta': 'Normal chat'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(seen, isEmpty);
      expect(calls.where((c) => c['method'] == 'session.resume'), isEmpty);
    },
  );
  test(
    'reconnecting rebuilds the in-flight reply without resubmitting work',
    () async {
      final seen = <HermesGroupLiveReply>[];
      final sub = service.watchGroupReplies(group).listen(seen.add);
      addTearDown(sub.cancel);
      await until(() => seen.isNotEmpty);
      await rpc.disconnect();
      await until(
        () => calls.where((c) => c['method'] == 'session.resume').length >= 2,
      );
      push('message.delta', 3, {'delta': 'lo again'});
      await until(() => seen.last.text == 'Hello again');
      expect(
        calls.where(
          (c) => c['method'] == 'prompt.submit' || c['method'] == 'groups.send',
        ),
        isEmpty,
      );
    },
  );
}
