import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final class _StatusAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode({'auth_required': false, 'gateway_running': true}),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// A gateway socket that answers each request with [answer] (a result, or
/// a `{'error': ...}` map, or a future of one), else an empty object.
final class _Gateway {
  _Gateway([Object? Function(String method, Map params)? answer])
    : answer = answer ?? ((_, _) => null) {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': {}},
          }),
        ),
      );
      return incoming.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      sent.add(frame);
      final id = frame['id'];
      if (id == null) return;
      final method = frame['method']?.toString() ?? '';
      void reply(Object? value) {
        final reply = value ?? {};
        final error = reply is Map ? reply['error'] : null;
        incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            if (error != null) 'error': error else 'result': reply,
          }),
        );
      }

      final answer = this.answer(method, frame['params'] as Map);
      if (answer is Future) {
        answer.then(reply);
      } else {
        scheduleMicrotask(() => reply(answer));
      }
    });
  }

  Object? Function(String method, Map params) answer;
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];

  List<Map<String, dynamic>> params(String method) => [
    for (final frame in sent)
      if (frame['method'] == method)
        Map<String, dynamic>.from(frame['params'] as Map),
  ];
}

HermesDesktopApiService _service(_Gateway gateway) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopProfile: 'ops',
      desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
    ),
    dio: Dio()..httpClientAdapter = _StatusAdapter(),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => gateway.channel,
    ),
  );
  addTearDown(service.close);
  addTearDown(gateway.incoming.close);
  return service;
}

const _research = {
  'member_id': 'research',
  'profile': 'research',
  'handle': 'research',
  'display_name': 'Research',
};
const _scout = {'member_id': 'scout', 'profile': 'scout', 'handle': 'scout'};

Map<String, Object?> _roomJson({int latest = 0, int epoch = 1}) => {
  'room_id': 'standup',
  'name': 'Daily standup',
  'members': [_research, _scout],
  'authority_gateway_id': 'install:synthetic',
  'authority_epoch': epoch,
  'latest_seq': latest,
  'updated_at': 1767229200.0,
};

HermesRoom _room() => HermesRoom.fromJson(_roomJson())!;

int _seq = 0;

HermesRoomEvent _event(
  String kind,
  Map<String, Object?> payload, {
  Map<String, Object?>? actor,
  String? id,
}) {
  final seq = ++_seq;
  return HermesRoomEvent.fromJson({
    'seq': seq,
    'kind': kind,
    'event_id': id ?? 'event-$seq',
    'actor': ?actor,
    'payload': payload,
    'created_at': 1767229200.0,
  })!;
}

HermesRoomEvent _user(String id, String text, {String? thread}) => _event(
  'message.user',
  {'text': text, 'thread_id': thread ?? id},
  actor: {'kind': 'user', 'id': 'desktop'},
  id: id,
);

HermesRoomEvent _member(String member, String discussion, String text) =>
    _event(
      'message.member',
      {
        'text': text,
        'discussion_event_id': discussion,
        'thread_id': discussion,
        'member_id': member,
      },
      actor: {'kind': 'member', 'id': member, 'profile': member},
    );

HermesRoomEvent _turn(
  String kind,
  String member,
  String discussion, [
  Map<String, Object?> extra = const {},
]) => _event(kind, {
  'member_id': member,
  'discussion_event_id': discussion,
  'thread_id': discussion,
  ...extra,
});

HermesRoomEvent _bounded(String discussion) => _event('room.activity', {
  'status': 'bounded',
  'reason_code': 'max_rounds',
  'thread_id': discussion,
  'discussion_event_id': discussion,
});

/// The connection in use, which a test switches.
final class _ActiveService extends Notifier<HermesBackendService?> {
  _ActiveService(this.initial);

  final HermesBackendService? initial;

  @override
  HermesBackendService? build() => initial;

  void set(HermesBackendService? service) => state = service;
}

final _activeService =
    NotifierProvider<_ActiveService, HermesBackendService?>(
      () => _ActiveService(null),
    );

void main() {
  setUp(() => _seq = 0);

  group('models', () {
    test('a room keeps its roster with handles and labels', () {
      final room = HermesRoom.fromJson({
        ..._roomJson(latest: 12, epoch: 2),
        'members': [
          _research,
          _scout,
          {'member_id': 'no-profile'},
          _research,
        ],
      })!;

      check(
        room.members.map((m) => m.name).toList(),
      ).deepEquals(['Research', 'scout']);
      check(room.memberProfiles).deepEquals(['research', 'scout']);
      check(room.latestSeq).equals(12);
      check(room.authorityEpoch).equals(2);
      check(room.member('scout')!.handle).equals('scout');
    });

    test('a bot is seated as itself', () {
      final member = HermesRoomMember.forBot(
        const HermesBot(name: 'research', title: 'Research'),
      );

      check(member.toCreateJson()).deepEquals({
        'member_id': 'research',
        'profile': 'research',
        'handle': 'research',
        'target': {'kind': 'local', 'profile': 'research'},
        'display_name': 'Research',
      });
      check(
        HermesRoomMember.forBot(
          const HermesBot(name: 'scout', title: 'scout'),
        ).toCreateJson().containsKey('display_name'),
      ).isFalse();
    });

    test('state carries settings, live work and pending decisions', () {
      final state = HermesRoomState.fromJson({
        'room': _roomJson(),
        'context': {
          'purpose': 'Plan the week',
          'notes': 'Keep it short',
          'routing': 'lead',
          'lead_member_id': 'research',
        },
        'driver_status': {
          'working': true,
          'member_activity': [
            {
              'member_id': 'research',
              'status': 'running',
              'started_at': 100.0,
              'tool': 'terminal',
            },
            {'member_id': 'scout'},
          ],
          'pending_actions': [
            {
              'kind': 'approval',
              'member_id': 'research',
              'task_id': 'task-1',
              'execution_generation': 1,
              'request_id': 'req-1',
              'approval': {
                'request_id': 'req-1',
                'command': 'ls -la',
                'choices': ['once', 'deny', 'always'],
              },
            },
            {'kind': 'approval', 'member_id': 'scout'},
          ],
          'max_continues': 5,
          'routing_modes': ['everyone', 'lead', 'auto', 'other'],
        },
      })!;

      check(state.context!)
        ..has((c) => c.routing, 'routing').equals(HermesRoomRouting.lead)
        ..has((c) => c.leadMemberId, 'lead').equals('research');
      final driver = state.driver!;
      check(driver.memberActivity.single.tool).equals('terminal');
      check(driver.pendingActions.single)
        ..has((a) => a.canAllowOnce, 'allow').isTrue()
        ..has((a) => a.canDeny, 'deny').isTrue();
      check(
        driver.pendingActions.single.approval!.choices,
      ).deepEquals(['once', 'deny']);
      check(driver.maxContinues).equals(5);
      check(driver.routingModes!).deepEquals(HermesRoomRouting.values.toSet());

      final noRouting = HermesRoomContext.fromJson({
        'purpose': 'x',
        'notes': '',
      })!;
      check(noRouting.routing).isNull();
      check(HermesRoomState.fromJson({'room': {}})).isNull();
    });

    test('Allow once needs a command or a labelled operation', () {
      HermesRoomPendingAction action(Map<String, Object?> approval) =>
          HermesRoomPendingAction.fromJson({
            'kind': 'approval',
            'member_id': 'research',
            'task_id': 'task-1',
            'execution_generation': 2,
            'request_id': 'req-1',
            'approval': {
              'choices': ['once', 'deny'],
              ...approval,
            },
          })!;

      check(action({'command': 'rm -rf build'}).canAllowOnce).isTrue();
      check(action({'description': 'Delete build'}).canAllowOnce).isFalse();
      check(
        action({
          'command': '<browser> (navigate)',
          'description': 'Open the page',
        }).canAllowOnce,
      ).isTrue();
      check(action({'command': '<browser> (navigate)'}).canAllowOnce).isFalse();
      check(
        action({'command': 'ls', 'request_id': 'other'}).canAllowOnce,
      ).isFalse();
    });

    test('a log page keeps only new, well-formed events', () {
      final page = HermesRoomLogPage.fromJson({
        'events': [
          {
            'seq': 3,
            'kind': 'message.user',
            'payload': {'text': 'old'},
          },
          {
            'seq': 5,
            'kind': 'message.user',
            'payload': {'text': 'hi'},
          },
          {'seq': 'x', 'kind': 'message.user'},
          {'seq': 6, 'payload': {}},
          {'seq': 7, 'kind': 'room.renamed', 'payload': 'bad'},
        ],
        'cursor': 7,
        'latest_seq': 9,
        'has_more': true,
      }, 4);

      check(page.events.map((e) => e.seq).toList()).deepEquals([5, 7]);
      check(page.events.first.text).equals('hi');
      check(page.cursor).equals(7);
      check(page.hasMore).isTrue();
    });

    test('a reply keeps the indentation it opens with', () {
      const reply = '    final total = 3;\n\nThat is the count.';
      final event = HermesRoomEvent.fromJson({
        'seq': 2,
        'kind': 'message.member',
        'payload': {'text': reply},
      });

      check(event?.text).equals(reply);
    });
  });

  group('timeline', () {
    test('shows messages by author with notices and routing', () {
      final events = [
        _user('m1', 'Morning @research'),
        _event('room.routed', {
          'discussion_event_id': 'm1',
          'thread_id': 'm1',
          'member_ids': ['research', 'gone'],
          'everyone': false,
          'fallback': false,
        }),
        _member('research', 'm1', 'Hello'),
        _turn('turn.failed', 'scout', 'm1', {'error': 'Model timed out'}),
        _event(
          'message.user',
          {'text': 'Digest ready', 'thread_id': 'cron-1'},
          actor: {
            'kind': 'user',
            'id': 'cron:digest',
            'display_name': 'Digest',
          },
        ),
        _event('room.renamed', {'name': 'x'}),
        _event('room.stop_requested', {'cancel_id': 'c'}),
      ];

      final items = projectHermesRoomTimeline(events, _room());

      check(items.length).equals(6);
      check(items[0]).isA<HermesRoomMessageItem>()
        ..has((i) => i.own, 'own').isTrue()
        ..has((i) => i.author, 'author').equals('');
      check(items[1]).isA<HermesRoomRouteItem>()
        ..has((i) => i.kind, 'kind').equals(HermesRoomRouteKind.routedTo)
        ..has((i) => i.names, 'names').deepEquals(['Research']);
      check(items[2]).isA<HermesRoomMessageItem>()
        ..has((i) => i.author, 'author').equals('Research')
        ..has((i) => i.member?.memberId, 'member').equals('research');
      check(items[3]).isA<HermesRoomNoticeItem>()
        ..has((i) => i.kind, 'kind').equals(HermesRoomNoticeKind.turnFailed)
        ..has((i) => i.memberName, 'name').equals('scout')
        ..has((i) => i.detail, 'detail').equals('Model timed out');
      check(items[4]).isA<HermesRoomMessageItem>()
        ..has((i) => i.scheduled, 'scheduled').isTrue()
        ..has((i) => i.author, 'author').equals('Digest');
      check(items[5])
          .isA<HermesRoomNoticeItem>()
          .has((i) => i.kind, 'kind')
          .equals(HermesRoomNoticeKind.stopped);
    });

    test('a pause offers Continue until something moves it on', () {
      final open = [
        _user('m1', 'Debate this'),
        _member('research', 'm1', 'One'),
        _member('scout', 'm1', 'Two'),
        _bounded('m1'),
      ];
      HermesRoomPauseItem pause(List<HermesRoomEvent> events, int max) =>
          projectHermesRoomTimeline(
            events,
            _room(),
            maxContinues: max,
          ).whereType<HermesRoomPauseItem>().first;

      check(pause(open, 5))
        ..has((p) => p.messageCount, 'count').equals(2)
        ..has((p) => p.actionable, 'actionable').isTrue()
        ..has((p) => p.discussionEventId, 'discussion').equals('m1');
      check(pause(open, 0).actionable).isFalse();

      final continued = [
        ...open,
        _event('room.continued', {
          'discussion_event_id': 'm1',
          'thread_id': 'm1',
          'grant': 1,
        }),
      ];
      check(pause(continued, 5).actionable).isFalse();
      check(
            projectHermesRoomTimeline(continued, _room(), maxContinues: 5).last,
          )
          .isA<HermesRoomRouteItem>()
          .has((i) => i.kind, 'kind')
          .equals(HermesRoomRouteKind.continued);

      final stopped = [
        ...open,
        _event('room.stop_requested', {'cancel_id': 'c'}),
      ];
      check(pause(stopped, 5).actionable).isFalse();

      final newMessage = [...open, _user('m2', 'Again', thread: 'm1')];
      check(pause(newMessage, 5).actionable).isFalse();

      // A Hermes without Continue shows the limit as a notice.
      check(projectHermesRoomTimeline(open, _room()).last)
          .isA<HermesRoomNoticeItem>()
          .has((i) => i.kind, 'kind')
          .equals(HermesRoomNoticeKind.workLimit);
    });

    test('a pause counts Continues the shown log no longer holds', () {
      HermesRoomPauseItem pause(List<HermesRoomEvent> events) =>
          projectHermesRoomTimeline(
            events,
            _room(),
            maxContinues: 2,
          ).whereType<HermesRoomPauseItem>().last;
      HermesRoomEvent pausedAfter(int continues) => _event(
        'room.activity',
        {
          'status': 'bounded',
          'reason_code': 'max_rounds',
          'thread_id': 'm1',
          'discussion_event_id': 'm1',
        },
        id: 'dactivity:m1:max_rounds:c$continues',
      );

      // Only the second Continue is still shown; it names its number.
      check(
        pause([
          _event('room.continued', {
            'discussion_event_id': 'm1',
            'thread_id': 'm1',
            'grant': 2,
          }),
          _member('scout', 'm1', 'Two'),
          _bounded('m1'),
        ]).actionable,
      ).isFalse();
      // No Continue is shown; the pause's id says how many came first.
      check(
        pause([_member('scout', 'm1', 'Two'), pausedAfter(2)]).actionable,
      ).isFalse();
      check(
        pause([_member('scout', 'm1', 'Two'), pausedAfter(1)]).actionable,
      ).isTrue();
    });

    test('a reply that asks a teammate shows the handoff', () {
      final events = [
        _user('m1', 'Plan it'),
        _member('research', 'm1', 'Over to @scout for numbers'),
        _turn('turn.settled', 'research', 'm1'),
        _member('scout', 'm1', 'Numbers'),
        _turn('turn.settled', 'scout', 'm1'),
      ];

      final handoff = projectHermesRoomTimeline(
        events,
        _room(),
      ).whereType<HermesRoomRouteItem>().single;

      check(handoff)
        ..has((i) => i.kind, 'kind').equals(HermesRoomRouteKind.handoff)
        ..has((i) => i.lead, 'from').equals('Research')
        ..has((i) => i.names, 'to').deepEquals(['scout'])
        ..has((i) => i.seq, 'after').equals(events[1].seq);
    });
  });

  group('member status', () {
    test('live work beats the last outcome of the current discussion', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000 * 1000);
      final events = [
        _user('m1', 'Go'),
        _turn('turn.failed', 'scout', 'm1', {
          'reason_code': 'provider_error',
          'error': 'boom',
        }),
        _turn('turn.settled', 'research', 'm1', {'passed': true}),
      ];
      final members = _room().members;

      var statuses = hermesRoomMemberStatuses(events, members, [
        HermesRoomMemberActivity(
          memberId: 'research',
          status: 'running',
          startedAt: now.subtract(const Duration(seconds: 7)),
          tool: 'terminal',
        ),
      ], now);
      check(statuses['research']!)
        ..has((s) => s.kind, 'kind').equals(HermesRoomMemberStatusKind.working)
        ..has((s) => s.tool, 'tool').equals('terminal')
        ..has((s) => s.elapsed, 'elapsed').equals(const Duration(seconds: 7));
      check(statuses['scout']!)
        ..has((s) => s.kind, 'kind').equals(HermesRoomMemberStatusKind.failed)
        ..has((s) => s.reason, 'reason').equals('provider_error');

      statuses = hermesRoomMemberStatuses(events, members, [
        HermesRoomMemberActivity(
          memberId: 'research',
          status: 'running',
          startedAt: now.subtract(const Duration(minutes: 5)),
          progressAt: now.subtract(const Duration(minutes: 3)),
        ),
        const HermesRoomMemberActivity(memberId: 'scout', status: 'queued'),
      ], now);
      check(
        statuses['research']!.kind,
      ).equals(HermesRoomMemberStatusKind.stalled);
      check(statuses['scout']!.kind).equals(HermesRoomMemberStatusKind.queued);

      // A newer message in the thread starts a new discussion.
      statuses = hermesRoomMemberStatuses(
        [...events, _user('m2', 'Again', thread: 'm1')],
        members,
        const [],
        now,
      );
      check(statuses['scout']!.kind).equals(HermesRoomMemberStatusKind.idle);

      // The thread's message left the shown log; its outcome still counts.
      statuses = hermesRoomMemberStatuses(
        events.sublist(1),
        members,
        const [],
        now,
      );
      check(statuses['scout']!.kind).equals(HermesRoomMemberStatusKind.failed);
      check(
        formatHermesRoomElapsed(const Duration(seconds: 80)),
      ).equals('1m20s');
      check(
        formatHermesRoomElapsed(const Duration(minutes: 65)),
      ).equals('1h05m');
    });
  });

  group('mentions', () {
    test('complete the handle being typed', () {
      const text = 'Hi @re and more';
      final query = hermesRoomMentionQuery(text, 6)!;
      check(query.start).equals(3);
      check(query.query).equals('re');
      check(hermesRoomMentionQuery('mail@re', 7)).isNull();
      check(hermesRoomMentionQuery('@', 1)!.query).equals('');

      final members = _room().members;
      check(
        hermesRoomMentionCandidates(members, 're').map((m) => m.handle),
      ).deepEquals(['research']);
      check(
        hermesRoomMentionCandidates(members, 'ou').map((m) => m.handle),
      ).deepEquals(['scout']);

      final inserted = insertHermesRoomMention(text, query, 6, 'research');
      check(inserted.text).equals('Hi @research and more');
      check(inserted.caret).equals(13);
      final atEnd = insertHermesRoomMention(
        '@sc',
        (start: 0, query: 'sc'),
        3,
        'scout',
      );
      check(atEnd.text).equals('@scout ');
      check(atEnd.caret).equals(7);
      check(hermesRoomTextMentions('ask @Scout.', 'scout')).isTrue();
      check(hermesRoomTextMentions('mail@scout', 'scout')).isFalse();
    });
  });

  group('service', () {
    test('reads a room: state, then its newest log pages', () async {
      final gateway = _Gateway((method, params) {
        switch (method) {
          case 'groups.state':
            return {
              'room': _roomJson(latest: 1500),
              'context': {'purpose': '', 'notes': ''},
            };
          case 'groups.log':
            final since = params['since_seq'] as int;
            final next = since + 2;
            return {
              'events': [
                {
                  'seq': since + 1,
                  'kind': 'message.user',
                  'payload': {'text': 'a'},
                },
                {
                  'seq': next,
                  'kind': 'message.user',
                  'payload': {'text': 'b'},
                },
              ],
              'cursor': next,
              'latest_seq': 1500,
              'has_more': next < 504,
            };
        }
        return null;
      });
      final service = _service(gateway);

      final state = await service.roomState('standup');
      final events = await service.roomEventsSince(
        'standup',
        sinceSeq: 0,
        latestSeq: state.room.latestSeq,
      );

      check(
        gateway.params('groups.state').single,
      ).deepEquals({'profile': 'ops', 'room_id': 'standup'});
      final logs = gateway.params('groups.log');
      check(logs.first).deepEquals({
        'profile': 'ops',
        'room_id': 'standup',
        'since_seq': 500,
        'limit': 15,
      });
      check(logs.map((p) => p['since_seq']).toList()).deepEquals([500, 502]);
      check(
        events.map((e) => e.seq).toList(),
      ).deepEquals([501, 502, 503, 504]);
    });

    test('creates, renames, saves settings and disbands', () async {
      final gateway = _Gateway((method, params) {
        if (method == 'groups.create') {
          return {
            'room': {
              'room_id': params['room_id'],
              'name': params['name'],
              'members': params['members'],
            },
          };
        }
        if (method == 'groups.context') {
          return {'context': params, 'event': {}};
        }
        return null;
      });
      final service = _service(gateway);
      const bots = [
        HermesBot(name: 'research', title: 'Research'),
        HermesBot(name: 'scout', title: 'Scout'),
      ];

      final room = await service.createRoom(
        name: 'Standup',
        members: bots.map(HermesRoomMember.forBot).toList(),
      );
      check(room.name).equals('Standup');
      check(
        room.members.map((m) => m.name).toList(),
      ).deepEquals(['Research', 'Scout']);
      final create = gateway.params('groups.create').single;
      check(
        create.keys.toSet(),
      ).deepEquals({'profile', 'room_id', 'name', 'members'});
      check((create['members'] as List).first as Map).deepEquals({
        'member_id': 'research',
        'profile': 'research',
        'handle': 'research',
        'target': {'kind': 'local', 'profile': 'research'},
        'display_name': 'Research',
      });

      await service.renameRoom(room.id, 'Weekly');
      check(gateway.params('groups.rename').single)
        ..has((p) => p['name'], 'name').equals('Weekly')
        ..has((p) => p['event_id'], 'event').isA<String>();

      await service.setRoomContext(
        room.id,
        const HermesRoomContext(
          purpose: ' Plan ',
          notes: 'Notes',
          routing: HermesRoomRouting.lead,
          leadMemberId: 'scout',
        ),
      );
      await service.setRoomContext(
        room.id,
        const HermesRoomContext(purpose: 'Plan', notes: ''),
      );
      final saves = gateway.params('groups.context');
      check(saves.first)
        ..has((p) => p['purpose'], 'purpose').equals('Plan')
        ..has((p) => p['routing'], 'routing').equals('lead')
        ..has((p) => p['lead_member_id'], 'lead').equals('scout');
      // A Hermes without routing is sent only purpose and notes.
      check(saves.last.keys.toSet()).deepEquals({
        'profile',
        'room_id',
        'event_id',
        'purpose',
        'notes',
      });

      await service.disbandRoom(room.id);
      check(
        gateway.params('groups.disband').single.keys.toSet(),
      ).deepEquals({'profile', 'room_id', 'cancel_id'});
    });

    test('sends with its own event id and a confirmed receipt', () async {
      final gateway = _Gateway((method, params) {
        if (method != 'groups.send') return null;
        return {
          'event': {},
          'client_event_id': params['event_id'],
          'accepted': true,
        };
      });
      final service = _service(gateway);
      final send = HermesRoomSend(text: 'Hi @scout');

      await service.sendRoomMessage('standup', send);

      check(gateway.params('groups.send').single).deepEquals({
        'profile': 'ops',
        'room_id': 'standup',
        'event_id': send.eventId,
        'payload': {'text': 'Hi @scout', 'thread_id': send.eventId},
      });

      gateway.answer = (_, _) => {'client_event_id': 'other'};
      await check(service.sendRoomMessage('standup', send)).throws();
    });

    test('stops, continues, approves and retries exact work', () async {
      final gateway = _Gateway(
        (method, _) => method == 'groups.stop' ? {'cancelled': 2} : null,
      );
      final service = _service(gateway);
      final approval = HermesRoomPendingAction.fromJson({
        'kind': 'approval',
        'member_id': 'research',
        'task_id': 'task-1',
        'execution_generation': 3,
        'request_id': 'req-1',
        'approval': {
          'command': 'ls',
          'choices': ['deny'],
        },
      })!;

      check(await service.stopRoom('standup', cancelId: 'stop-1')).equals(2);
      await service.continueRoomDiscussion('standup', 'm1');
      await service.answerRoomAction('standup', approval, choice: 'deny');
      await check(
        service.answerRoomAction('standup', approval, choice: 'once'),
      ).throws<StateError>();
      await service.answerRoomAction(
        'standup',
        HermesRoomPendingAction.fromJson({
          'kind': 'retry',
          'member_id': 'scout',
          'task_id': 'task-2',
          'execution_generation': 1,
        })!,
      );

      check(
        gateway.params('groups.stop').single['cancel_id'],
      ).equals('stop-1');
      check(gateway.params('groups.continue').single).deepEquals({
        'profile': 'ops',
        'room_id': 'standup',
        'discussion_event_id': 'm1',
      });
      check(gateway.params('groups.approve').single).deepEquals({
        'profile': 'ops',
        'room_id': 'standup',
        'member_id': 'research',
        'task_id': 'task-1',
        'execution_generation': 3,
        'choice': 'deny',
        'request_id': 'req-1',
      });
      check(gateway.params('groups.retry').single.keys.toSet()).deepEquals({
        'profile',
        'room_id',
        'member_id',
        'task_id',
        'execution_generation',
      });
    });

    test('names why Hermes refused', () async {
      final gateway = _Gateway(
        (_, _) => {
          'error': {
            'code': 4001,
            'message': 'invalid_params',
            'data': {
              'reason': 'invalid_params',
              'field': 'members',
              'detail': "member 1 profile 'scout' is not local",
              'admitted': false,
            },
          },
        },
      );
      final service = _service(gateway);

      Object? refusal;
      try {
        await service.sendRoomMessage('standup', HermesRoomSend(text: 'x'));
      } catch (error) {
        refusal = error;
      }
      check(hermesRoomSendAdmittedNothing(refusal!)).isTrue();
      check(
        hermesRoomRefusalDetail(refusal),
      ).equals("member 1 profile 'scout' is not local");
      check(
        hermesRoomRefusalDetail(
          const HermesDesktopRpcException('permission_denied', code: 4001),
        ),
      ).isNull();
    });
  });

  test('a log page of the longest replies fits one socket frame', () {
    // The page size the service asks for (`limit`, checked above).
    const pageSize = 15;
    final reply = jsonEncode({
      'seq': 1,
      'kind': 'message.member',
      'event_id': 'member:${'e' * 64}',
      'actor': {'kind': 'member', 'id': 'research'},
      // Every character needs an escape in JSON.
      'payload': {'text': '\n' * kMaxHermesRoomTextCharacters},
    });
    check(
      pageSize * reply.length,
    ).isLessThan(kMaxHermesDesktopFrameCharacters);
  });

  group('controller', () {
    ProviderContainer containerFor(HermesDesktopApiService service) {
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('reads only what is new, and again from a new epoch', () async {
      var latest = 2;
      var epoch = 1;
      final gateway = _Gateway((method, params) {
        switch (method) {
          case 'groups.state':
            return {'room': _roomJson(latest: latest, epoch: epoch)};
          case 'groups.log':
            final since = params['since_seq'] as int;
            return {
              'events': [
                for (var seq = since + 1; seq <= latest; seq++)
                  {
                    'seq': seq,
                    'kind': 'message.user',
                    'payload': {'text': 'm$seq'},
                  },
              ],
              'cursor': latest,
              'latest_seq': latest,
              'has_more': false,
            };
        }
        return null;
      });
      final container = containerFor(_service(gateway));
      final sub = container.listen(hermesRoomProvider('standup'), (_, _) {});
      addTearDown(sub.close);
      final room = container.read(hermesRoomProvider('standup').notifier);

      await room.refresh();
      check(sub.read().events.map((e) => e.seq).toList()).deepEquals([1, 2]);
      check(sub.read().loaded).isTrue();

      latest = 3;
      await room.refresh();
      check(
        sub.read().events.map((e) => e.seq).toList(),
      ).deepEquals([1, 2, 3]);
      check(
        gateway.params('groups.log').map((p) => p['since_seq']).toList(),
      ).deepEquals([0, 2]);

      epoch = 2;
      latest = 1;
      await room.refresh();
      check(sub.read().events.map((e) => e.seq).toList()).deepEquals([1]);
    });

    test('resends under the same id until Hermes has the message', () async {
      Object? answer(Map params) => {
        'error': {'code': 5112, 'message': 'driver busy'},
      };
      var sendAnswer = answer;
      final gateway = _Gateway((method, params) {
        if (method == 'groups.send') return sendAnswer(params);
        if (method == 'groups.state') return {'room': _roomJson()};
        if (method == 'groups.log') {
          return {'events': [], 'cursor': 0, 'has_more': false};
        }
        return null;
      });
      final container = containerFor(_service(gateway));
      final sub = container.listen(hermesRoomProvider('standup'), (_, _) {});
      addTearDown(sub.close);
      final room = container.read(hermesRoomProvider('standup').notifier);

      await check(room.send('Hello')).throws();
      check(sub.read().unsentText).equals('Hello');
      await check(room.send('Hello')).throws();
      final ids = gateway.params('groups.send').map((p) => p['event_id']);
      check(ids.toSet().length).equals(1);

      sendAnswer = (_) => {
        'error': {
          'code': 4001,
          'message': 'invalid_params',
          'data': {'admitted': false},
        },
      };
      await check(room.send('Hello')).throws();
      check(sub.read().unsentText).isNull();

      sendAnswer = (params) => {
        'client_event_id': params['event_id'],
        'accepted': true,
      };
      await room.send('Hello');
      final all = gateway.params('groups.send').map((p) => p['event_id']);
      check(all.toSet().length).equals(2);
      check(sub.read().sending).isFalse();
    });

    test('an edit after an unclear answer takes the same id', () async {
      final log = <Map<String, Object?>>[];
      final ids = <String>[];
      Object? answer(String method, Map params) {
        switch (method) {
          case 'groups.state':
            return {'room': _roomJson(latest: log.length)};
          case 'groups.log':
            final since = params['since_seq'] as int;
            return {
              'events': [
                for (final event in log)
                  if ((event['seq'] as int) > since) event,
              ],
              'cursor': log.length,
              'has_more': false,
            };
          case 'groups.send':
            final id = params['event_id'] as String;
            ids.add(id);
            final logId = 'user:${sha256.convert(utf8.encode(id))}';
            if (log.any((event) => event['event_id'] == logId)) {
              return {
                'error': {
                  'code': 4111,
                  'message': 'event_id already exists with different content',
                },
              };
            }
            // Hermes posts the message, but its receipt is lost.
            log.add({
              'seq': log.length + 1,
              'kind': 'message.user',
              'event_id': logId,
              'actor': {'kind': 'user', 'id': 'desktop'},
              'payload': (params['payload'] as Map).cast<String, Object?>(),
            });
            return {
              'error': {'code': 5112, 'message': 'driver busy'},
            };
        }
        return null;
      }

      final gateway = _Gateway(answer);
      final container = containerFor(_service(gateway));
      final sub = container.listen(hermesRoomProvider('standup'), (_, _) {});
      addTearDown(sub.close);
      final room = container.read(hermesRoomProvider('standup').notifier);

      await check(room.send('Helo')).throws();
      await check(room.send('Hello')).throws();
      // Hermes refused the edit: the first words were already posted.
      check(ids.toSet().length).equals(1);
      check(log.length).equals(1);

      // The log shows the message, so the next words are a new message.
      await room.refresh();
      check(sub.read().unsentText).isNull();
      await check(room.send('Hello')).throws();
      check(ids.toSet().length).equals(2);
    });

    test('an unclear message keeps its id across a connection '
        'switch', () async {
      final gateway = _Gateway((method, params) {
        if (method == 'groups.send') {
          return {
            'error': {'code': 5112, 'message': 'driver busy'},
          };
        }
        if (method == 'groups.state') return {'room': _roomJson()};
        if (method == 'groups.log') {
          return {'events': [], 'cursor': 0, 'has_more': false};
        }
        return null;
      });
      final service = _service(gateway);
      final container = ProviderContainer(
        overrides: [
          _activeService.overrideWith(() => _ActiveService(service)),
          hermesApiServiceProvider.overrideWith(
            (ref) => ref.watch(_activeService),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(hermesRoomProvider('standup'), (_, _) {});
      addTearDown(sub.close);
      HermesRoomController room() =>
          container.read(hermesRoomProvider('standup').notifier);
      final active = container.read(_activeService.notifier);

      await check(room().send('Hello')).throws();
      active.set(null);
      check(sub.read().unsentText).equals('Hello');
      active.set(service);
      check(sub.read().unsentText).equals('Hello');
      await check(room().send('Hello')).throws();
      final ids = gateway.params('groups.send').map((p) => p['event_id']);
      check(ids.toSet().length).equals(1);
    });

    test('a save shows what Hermes saved, not a read from before', () async {
      var stored = <String, Object?>{'purpose': 'Old', 'notes': ''};
      Completer<void>? hold;
      var failState = false;
      final gateway = _Gateway((method, params) {
        switch (method) {
          case 'groups.state':
            if (failState) {
              return {
                'error': {'code': 5000, 'message': 'unavailable'},
              };
            }
            final snapshot = {'room': _roomJson(), 'context': {...stored}};
            final held = hold;
            return held == null ? snapshot : held.future.then((_) => snapshot);
          case 'groups.log':
            return {'events': [], 'cursor': 0, 'has_more': false};
          case 'groups.list':
            return {
              'rooms': [_roomJson()],
            };
          case 'groups.context':
            stored = {'purpose': params['purpose'], 'notes': params['notes']};
            return {'context': stored};
        }
        return null;
      });
      final container = containerFor(_service(gateway));
      final sub = container.listen(hermesRoomProvider('standup'), (_, _) {});
      addTearDown(sub.close);
      final room = container.read(hermesRoomProvider('standup').notifier);
      await room.refresh();
      check(sub.read().context!.purpose).equals('Old');

      // A poll reads the old settings and answers after the save.
      final held = hold = Completer<void>();
      final poll = room.refresh();
      await pumpEventQueue();
      hold = null;
      final save = room.saveContext(const HermesRoomContext(purpose: 'New'));
      await pumpEventQueue();
      held.complete();
      check((await save).purpose).equals('New');
      await poll;
      check(sub.read().context!.purpose).equals('New');

      // A read after the save that fails still shows the save.
      failState = true;
      final saved = await room.saveContext(
        const HermesRoomContext(purpose: 'Newer'),
      );
      check(saved.purpose).equals('Newer');
      check(sub.read().context!.purpose).equals('Newer');
    });

    test('a failed capabilities read is not a gateway without rooms', () async {
      var code = 5000;
      final gateway = _Gateway((method, _) {
        if (method != 'groups.capabilities') return null;
        return {
          'error': {'code': code, 'message': 'busy'},
        };
      });
      final container = containerFor(_service(gateway));
      final sub = container.listen(
        hermesRoomCapabilitiesProvider,
        (_, _) {},
      );
      addTearDown(sub.close);
      // Connecting reports the gateway's contract, which reads them again.
      Future<AsyncValue<HermesRoomCapabilities?>> settled() async {
        for (var turn = 0; turn < 50 && sub.read().isLoading; turn++) {
          await pumpEventQueue();
        }
        return sub.read();
      }

      check((await settled()).error).isA<HermesDesktopRpcException>();

      code = -32601;
      container.invalidate(hermesRoomCapabilitiesProvider);
      final unsupported = await settled();
      check(unsupported.hasError).isFalse();
      check(unsupported.value).isNull();
    });

    test('a room that left the gateway reads as gone', () async {
      final gateway = _Gateway((method, _) {
        if (method == 'groups.list') return {'rooms': []};
        return {
          'error': {'code': 4001, 'message': 'permission_denied'},
        };
      });
      final container = containerFor(_service(gateway));
      final sub = container.listen(hermesRoomProvider('standup'), (_, _) {});
      addTearDown(sub.close);

      await container.read(hermesRoomProvider('standup').notifier).refresh();

      check(sub.read())
        ..has((v) => v.gone, 'gone').isTrue()
        ..has((v) => v.readError, 'error').isNotNull();
    });
  });
}
