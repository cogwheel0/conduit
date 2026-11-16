@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/hermes/models/hermes_bot.dart' as core;
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart' as core;
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart'
    as core;
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart'
    as core;
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart'
    as core;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:conduitd/src/hermes_connection.dart';
import 'package:conduitd/src/hermes_rooms_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A synthetic two-bot room on a gateway that runs rooms.
Map<String, Object?> _roomJson({
  String name = 'Greenhouse crew',
  int latest = 4,
  bool working = false,
  List<Map<String, Object?>> pending = const [],
  List<Map<String, Object?>> activity = const [],
}) => {
  'room': {
    'room_id': 'room-1',
    'name': name,
    'members': [
      {'member_id': 'fern', 'profile': 'fern', 'handle': 'fern'},
      {
        'member_id': 'moss',
        'profile': 'moss',
        'handle': 'moss',
        'display_name': 'Moss',
      },
    ],
    'updated_at': 1767225600.0,
    'latest_seq': latest,
    'authority_epoch': 1,
  },
  'context': {
    'purpose': 'Plan the spring beds',
    'notes': '',
    'routing': 'everyone',
  },
  'driver_status': {
    'working': working,
    'pending_actions': pending,
    'member_activity': activity,
    'max_continues': 5,
    'routing_modes': ['everyone', 'lead', 'auto'],
  },
};

core.HermesRoomEvent _event(
  int seq,
  String kind, {
  Map<String, Object?> actor = const {'kind': 'user', 'id': 'desktop'},
  Map<String, Object?> payload = const {},
  String? eventId,
}) => core.HermesRoomEvent.fromJson({
  'seq': seq,
  'kind': kind,
  'event_id': eventId ?? 'e$seq',
  'actor': actor,
  'payload': payload,
  'created_at': 1767225600.0 + seq,
})!;

final _log = <core.HermesRoomEvent>[
  _event(
    1,
    'message.user',
    eventId: 'user:d1',
    payload: {'text': '@fern how many seed trays?', 'thread_id': 't1'},
  ),
  _event(
    2,
    'message.member',
    actor: {'kind': 'member', 'id': 'fern'},
    payload: {
      'text': 'Twelve trays.',
      'thread_id': 't1',
      'discussion_event_id': 'user:d1',
    },
  ),
  _event(
    3,
    'message.member',
    actor: {'kind': 'member', 'id': 'fern'},
    payload: {
      'text': 'Labels too. @moss can you check the shelf?',
      'thread_id': 't1',
      'discussion_event_id': 'user:d1',
    },
  ),
  _event(
    4,
    'turn.settled',
    payload: {
      'member_id': 'moss',
      'thread_id': 't1',
      'discussion_event_id': 'user:d1',
    },
  ),
];

/// A room controller that answers from a script instead of a gateway.
final class _ScriptedRoom extends core.HermesRoomController {
  _ScriptedRoom(super.roomId, this.script);

  final _Script script;

  @override
  core.HermesRoomView build() => const core.HermesRoomView();

  @override
  Future<void> refresh() async {
    script.reads++;
    final during = script.duringRead;
    script.duringRead = null;
    during?.call();
    final json = script.state;
    state = state.copyWith(
      snapshot: core.HermesRoomState.fromJson(json),
      events: script.events,
      loaded: true,
      gone: script.gone,
    );
  }

  @override
  Future<void> send(String text) async {
    script.sent.add(text);
    state = state.copyWith(sending: true, unsentText: text);
    final gate = script.sendGate;
    if (gate != null) await gate.future;
    final error = script.sendError;
    // An unclear answer keeps the words (Hermes may have them); a post or a
    // refusal settles them.
    final keeps = error != null && !core.hermesRoomSendAdmittedNothing(error);
    if (ref.mounted) {
      state = state.copyWith(sending: false, unsentText: keeps ? text : null);
    }
    if (error != null) throw error;
  }

  @override
  Future<int> stop() async {
    script.stops++;
    return 2;
  }

  @override
  Future<void> rename(String name) async {
    script.state = _roomJson(name: name);
    await refresh();
  }

  @override
  Future<void> answer(
    core.HermesRoomPendingAction action, {
    String? choice,
  }) async => script.answers.add('${action.taskId}:$choice');
}

final class _Script {
  Map<String, Object?> state = _roomJson();
  List<core.HermesRoomEvent> events = _log;
  bool gone = false;
  int reads = 0;
  int stops = 0;
  Object? sendError;

  /// Runs once inside the next read (a connection edit while it is out).
  void Function()? duringRead;

  /// Runs once inside the next roster read.
  void Function()? duringRoster;

  /// Holds a send until completed.
  Completer<void>? sendGate;
  final List<String> sent = <String>[];
  final List<String> answers = <String>[];
}

/// The Hermes service in use, switched by a test as a connection edit
/// switches it.
final class _Connection extends Notifier<HermesDesktopApiService?> {
  @override
  HermesDesktopApiService? build() => null;

  void use(HermesDesktopApiService? service) => state = service;
}

final _connection = NotifierProvider<_Connection, HermesDesktopApiService?>(
  _Connection.new,
);

/// The gateways a test's services tried to reach: none is reachable.
final _reached = <String>[];

HermesDesktopApiService _gateway(String address) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: address,
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
    ),
    rpc: HermesDesktopRpcClient(
      channelFactory: (uri, _, {httpClient}) {
        _reached.add(uri.host);
        throw StateError('No gateway in this test.');
      },
    ),
  );
  addTearDown(service.close);
  return service;
}

/// What a read changed has gone out: the service sends a room's view from
/// a microtask, which runs before this one.
Future<void> _sent() => Future<void>.microtask(() {});

void main() {
  late EventBus events;
  late List<EventEnvelope> seen;
  late ProviderContainer container;
  late HermesRoomsService rooms;
  late _Script script;

  setUp(() {
    events = EventBus();
    seen = <EventEnvelope>[];
    events.attach('w1', seen.add);
    events.subscribe(
      'w1',
      EventSubscription(
        events: ConduitEvents.all.toList(),
        scopes: <String>[hermesRoomScope('room-1')],
      ),
    );
    script = _Script();
    _reached.clear();
    container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWith((ref) => ref.watch(_connection)),
        hermesBotsProvider.overrideWith((ref) async {
          await Future<void>.value();
          final during = script.duringRoster;
          script.duringRoster = null;
          during?.call();
          return const <core.HermesBot>[
            core.HermesBot(name: 'fern', title: 'Fern', chatSessionId: 'bc-1'),
            core.HermesBot(name: 'moss', title: 'Moss'),
          ];
        }),
        core.hermesRoomCapabilitiesProvider.overrideWith(
          (ref) async => const core.HermesRoomCapabilities(driver: true),
        ),
        core.hermesRoomsProvider.overrideWith(
          (ref) async => <core.HermesRoom>[
            core.HermesRoom.fromJson(script.state['room'])!,
          ],
        ),
        core.hermesRoomProvider.overrideWith2(
          (roomId) => _ScriptedRoom(roomId, script),
        ),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(_connection.notifier)
        .use(_gateway('https://hermes.example'));
    rooms = HermesRoomsService(container, events);
    addTearDown(rooms.dispose);
  });

  List<HermesRoomView> changes() => <HermesRoomView>[
    for (final e in seen)
      if (e.event == ConduitEvents.hermesRoomsChanged)
        HermesRoomView.fromJson(e.payload),
  ];

  test('an open room reads as the phone projects it', () async {
    script.state = _roomJson(
      working: true,
      activity: [
        {
          'member_id': 'moss',
          'status': 'running',
          'tool': 'web_search',
          'started_at':
              DateTime.now()
                  .subtract(const Duration(seconds: 45))
                  .millisecondsSinceEpoch /
              1000,
        },
      ],
      pending: [
        {
          'kind': 'approval',
          'member_id': 'moss',
          'task_id': 't-9',
          'execution_generation': 1,
          'request_id': 'r-1',
          'approval': {
            'request_id': 'r-1',
            'command': 'ls seeds',
            'choices': ['once', 'deny'],
          },
        },
      ],
    );
    final view = await rooms.watch('w1', 'room-1');
    expect(view.loaded, isTrue);
    expect(view.room!.name, 'Greenhouse crew');
    expect(view.room!.members.map((m) => m.name), ['fern', 'Moss']);
    expect(view.running && view.working && view.room!.needsYou, isTrue);
    expect(view.routingModes, HermesRoomRouting.values);
    expect(view.context!.purpose, 'Plan the spring beds');

    final kinds = view.items.map((i) => i.kind).toList();
    expect(kinds, [
      HermesRoomItemKind.message,
      HermesRoomItemKind.message,
      HermesRoomItemKind.message,
      // Moss took a turn after Fern asked it.
      HermesRoomItemKind.route,
    ]);
    final handoff = view.items.last;
    expect(
      (handoff.route, handoff.lead),
      (HermesRoomRouteKind.handoff, 'fern'),
    );
    expect(handoff.names, ['Moss']);
    final action = view.actions.single;
    expect(action.summary, 'ls seeds');
    expect(action.choices, ['once', 'deny']);
  });

  test('a watched room goes out when it changes, and stops after', () async {
    await rooms.watch('w1', 'room-1');
    final reads = script.reads;
    await container.read(core.hermesRoomProvider('room-1').notifier).refresh();
    await _sent();
    expect(changes(), isEmpty, reason: 'nothing changed');

    script.events = [
      ..._log,
      _event(
        5,
        'message.member',
        actor: {'kind': 'member', 'id': 'moss'},
        payload: {'text': 'Shelf is clear.', 'thread_id': 't1'},
      ),
    ];
    await container.read(core.hermesRoomProvider('room-1').notifier).refresh();
    await _sent();
    final sent = changes();
    expect(sent, hasLength(1));
    expect(
      sent.single.items
          .lastWhere((i) => i.kind == HermesRoomItemKind.message)
          .text,
      'Shelf is clear.',
    );
    expect(
      seen.lastWhere((e) => e.event == ConduitEvents.hermesRoomsChanged).scope,
      hermesRoomScope('room-1'),
    );
    expect(script.reads, greaterThan(reads));

    rooms.unwatch('w1', 'room-1');
    seen.clear();
    script.events = _log;
    await container.read(core.hermesRoomProvider('room-1').notifier).refresh();
    await _sent();
    expect(changes(), isEmpty, reason: 'nobody shows it');
  });

  test('the list marks news since a room was last shown', () async {
    var list = await rooms.rooms('w1');
    expect(list.available && list.canCreate, isTrue);
    expect(list.seatable, ['fern', 'moss']);
    // First listed here: read up to where it is.
    expect(list.rooms.single.unread, isFalse);

    script.state = _roomJson(latest: 7);
    list = await rooms.rooms('w1');
    expect(list.rooms.single.unread, isTrue);

    // Shown: read.
    await rooms.watch('w1', 'room-1');
    rooms.unwatch('w1', 'room-1');
    list = await rooms.rooms('w1');
    expect(list.rooms.single.unread, isFalse);
  });

  test('a room left while its bots work stays read until they stop', () async {
    script.state = _roomJson(working: true);
    await rooms.watch('w1', 'room-1');
    final list = await rooms.rooms('w1');
    expect(list.rooms.single.working, isTrue);
    rooms.unwatch('w1', 'room-1');

    script.state = _roomJson();
    await container.read(core.hermesRoomProvider('room-1').notifier).refresh();
    await _sent();
    final updates = <HermesRooms>[
      for (final e in seen)
        if (e.event == ConduitEvents.hermesRoomsListChanged)
          HermesRooms.fromJson(e.payload),
    ];
    expect(updates.last.rooms.single.working, isFalse);
  });

  test('sending says whether Hermes has the words', () async {
    await rooms.watch('w1', 'room-1');
    var result = await rooms.send(
      const HermesRoomMessage(roomId: 'room-1', text: ' @fern hi '),
    );
    expect(result.sent, isTrue);
    expect(script.sent, ['@fern hi']);

    script.sendError = const HermesDesktopRpcException(
      'room_busy',
      code: 4111,
      data: {'admitted': false, 'detail': 'The room is closing.'},
    );
    result = await rooms.send(
      const HermesRoomMessage(roomId: 'room-1', text: 'again'),
    );
    expect(
      (result.sent, result.refused, result.detail),
      (false, true, 'The room is closing.'),
    );

    script.sendError = TimeoutException('no answer');
    result = await rooms.send(
      const HermesRoomMessage(roomId: 'room-1', text: 'again'),
    );
    expect((result.sent, result.refused), (false, false));
  });

  test('actions run on the room, open or not', () async {
    expect((await rooms.stop('room-1')).stopped, 2);
    final renamed = await rooms.rename(
      const HermesRoomRename(roomId: 'room-1', name: 'Seed swap'),
    );
    expect(renamed.name, 'Seed swap');

    script.state = _roomJson(
      pending: [
        {
          'kind': 'retry',
          'member_id': 'moss',
          'task_id': 't-3',
          'execution_generation': 2,
        },
      ],
    );
    await rooms.watch('w1', 'room-1');
    await rooms.answer(
      const HermesRoomAnswer(
        roomId: 'room-1',
        taskId: 't-3',
        executionGeneration: 2,
      ),
    );
    expect(script.answers, ['t-3:null']);
    await expectLater(
      rooms.answer(
        const HermesRoomAnswer(
          roomId: 'room-1',
          taskId: 'gone',
          executionGeneration: 1,
        ),
      ),
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', 'resource.conflict'),
      ),
    );
  });

  test('a new room needs a name and two to six bots', () async {
    for (final bad in <HermesRoomCreate>[
      const HermesRoomCreate(name: ' ', bots: ['fern', 'moss']),
      const HermesRoomCreate(name: 'Solo', bots: ['fern']),
      const HermesRoomCreate(
        name: 'Crowd',
        bots: ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
      ),
    ]) {
      await expectLater(
        rooms.create(bad),
        throwsA(
          isA<RpcError>().having((e) => e.code, 'code', 'rpc.invalidParams'),
        ),
      );
    }
    // A bot no longer listed: no room with fewer members than picked.
    await expectLater(
      rooms.create(
        const HermesRoomCreate(name: 'Crew', bots: ['fern', 'reed']),
      ),
      throwsA(
        isA<RpcError>().having((e) => e.code, 'code', 'resource.conflict'),
      ),
    );
  });

  test('a bot\'s chat is the bot\'s', () async {
    await rooms.bots();
    expect(rooms.botOf('bc-1')!.title, 'Fern');
    expect(rooms.botMetadataOf('bc-1')['hermesBotTitle'], 'Fern');
    expect(rooms.botOf('other'), isNull);
    expect(rooms.botMetadataOf('other'), isEmpty);
    final listed = await rooms.bots();
    expect(listed.available, isTrue);
    expect(listed.bots.map((b) => (b.name, b.sessionId)), [
      ('fern', 'bc-1'),
      ('moss', null),
    ]);
  });

  test('a connection has its own name, and a request under the last one is '
      'refused', () {
    final key = HermesConnectionKey(container);
    addTearDown(key.dispose);
    final first = key.current;
    expect(key.current, first, reason: 'the same connection keeps its name');
    key.require(first);
    key.require(null);

    container
        .read(_connection.notifier)
        .use(_gateway('https://other-hermes.example'));
    final second = key.current;
    expect(second, isNot(first));
    for (final check in <void Function()>[
      () => key.require(first),
      () => key.stillCurrent(first),
    ]) {
      expect(
        check,
        throwsA(
          isA<RpcError>()
              .having((e) => e.code, 'code', ConduitErrorCodes.sessionExpired)
              .having((e) => e.args['connection'], 'connection', first),
        ),
      );
    }
    key.require(second);
    // Another daemon run never names a connection as this one did.
    expect(second.split(':').first, isNotEmpty);
  });

  group('a room request belongs to the connection it was asked under', () {
    final expired = throwsA(
      isA<RpcError>().having(
        (e) => e.code,
        'code',
        ConduitErrorCodes.sessionExpired,
      ),
    );
    void switchConnection() => container
        .read(_connection.notifier)
        .use(_gateway('https://hermes-b.example'));

    test('an action begun before a connection edit is not done on the next '
        'one, even when the edit lands during its first read', () async {
      final began = rooms.connection.current;
      script.duringRead = switchConnection;
      await expectLater(
        rooms.send(
          HermesRoomMessage(roomId: 'room-1', text: 'hello', connection: began),
        ),
        expired,
      );
      expect(script.sent, isEmpty);
    });

    test('a request named for the last connection is refused before it '
        'reads or sends anything', () async {
      final last = rooms.connection.current;
      switchConnection();
      final reads = script.reads;
      for (final request in <Future<Object?> Function()>[
        () => rooms.watch('w1', 'room-1', connection: last),
        () => rooms.send(
          HermesRoomMessage(roomId: 'room-1', text: 'hi', connection: last),
        ),
        () => rooms.stop('room-1', connection: last),
        () => rooms.continueDiscussion(
          HermesRoomContinue(
            roomId: 'room-1',
            discussionEventId: 'user:d1',
            connection: last,
          ),
        ),
        () => rooms.answer(
          HermesRoomAnswer(
            roomId: 'room-1',
            taskId: 't-3',
            executionGeneration: 2,
            connection: last,
          ),
        ),
        () => rooms.rename(
          HermesRoomRename(
            roomId: 'room-1',
            name: 'Seed swap',
            connection: last,
          ),
        ),
        () => rooms.saveContext(
          HermesRoomContextEdit(
            roomId: 'room-1',
            context: const HermesRoomContextDto(purpose: 'Beds'),
            connection: last,
          ),
        ),
        () => rooms.disband('room-1', connection: last),
        () => rooms.create(
          HermesRoomCreate(
            name: 'Crew',
            bots: const ['fern', 'moss'],
            connection: last,
          ),
        ),
        () => rooms.avatar('fern', connection: last),
      ]) {
        await expectLater(request(), expired);
      }
      expect(script.reads, reads);
      expect(script.sent, isEmpty);
      expect(script.stops, 0);
      expect(_reached, isEmpty);
    });

    test('a room is not made on the last gateway with bots checked on the '
        'next one', () async {
      container
          .read(_connection.notifier)
          .use(_gateway('https://hermes-a.example'));
      // The roster read made for the new room sees the edit happen.
      script.duringRoster = switchConnection;
      await expectLater(
        rooms.create(
          HermesRoomCreate(
            name: 'Crew',
            bots: const ['fern', 'moss'],
            connection: rooms.connection.current,
          ),
        ),
        expired,
      );
      expect(_reached, isNot(contains('hermes-a.example')));
    });

    test('views and lists say which connection they were read on', () async {
      final first = rooms.connection.current;
      expect((await rooms.watch('w1', 'room-1')).connection, first);
      expect((await rooms.rooms('w1')).connection, first);
      expect((await rooms.bots()).connection, first);
      switchConnection();
      final second = rooms.connection.current;
      expect(second, isNot(first));
      expect((await rooms.rooms('w1')).connection, second);
    });
  });

  group('words Hermes may have stay with their room until settled', () {
    test('after the room is left', () async {
      await rooms.watch('w1', 'room-1');
      script.sendError = TimeoutException('no answer');
      final result = await rooms.send(
        const HermesRoomMessage(roomId: 'room-1', text: 'hello'),
      );
      expect((result.sent, result.refused), (false, false));
      rooms.unwatch('w1', 'room-1');
      await container.pump();
      final view = await rooms.watch('w1', 'room-1');
      expect(view.unsentText, 'hello');
    });

    test('when the room is left while they are being sent', () async {
      await rooms.watch('w1', 'room-1');
      script.sendError = TimeoutException('no answer');
      script.sendGate = Completer<void>();
      final sending = rooms.send(
        const HermesRoomMessage(roomId: 'room-1', text: 'hello'),
      );
      rooms.unwatch('w1', 'room-1');
      await container.pump();
      script.sendGate!.complete();
      await sending;
      await container.pump();
      final view = await rooms.watch('w1', 'room-1');
      expect(view.unsentText, 'hello');
    });

    test('and go once the room settles them', () async {
      await rooms.watch('w1', 'room-1');
      script.sendError = TimeoutException('no answer');
      await rooms.send(
        const HermesRoomMessage(roomId: 'room-1', text: 'hello'),
      );
      rooms.unwatch('w1', 'room-1');
      await container.pump();
      // The log shows them: the room lets them go, and is let go itself.
      final controller = container.read(
        core.hermesRoomProvider('room-1').notifier,
      );
      controller.state = controller.state.copyWith(unsentText: null);
      await container.pump();
      expect(
        container.read(core.hermesRoomProvider('room-1').notifier),
        isNot(same(controller)),
      );
    });
  });
}
