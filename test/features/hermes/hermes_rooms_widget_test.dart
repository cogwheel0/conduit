import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/views/hermes_room_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_room_timeline.dart';
import 'package:conduit/features/hermes/widgets/hermes_rooms_section.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_room_projection.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _bots = [
  HermesBot(name: 'research', title: 'Research'),
  HermesBot(name: 'scout', title: 'Scout'),
];

final _room = HermesRoom.fromJson({
  'room_id': 'standup',
  'name': 'Daily standup',
  'members': [
    {
      'member_id': 'research',
      'profile': 'research',
      'handle': 'research',
      'display_name': 'Research',
    },
    {
      'member_id': 'scout',
      'profile': 'scout',
      'handle': 'scout',
      'display_name': 'Scout',
    },
  ],
  'updated_at': 1767229200.0,
})!;

HermesRoomEvent _event(
  int seq,
  String kind,
  Map<String, Object?> payload, {
  Map<String, Object?>? actor,
  String? id,
}) => HermesRoomEvent.fromJson({
  'seq': seq,
  'kind': kind,
  'event_id': id ?? 'e$seq',
  'actor': ?actor,
  'payload': payload,
})!;

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

/// A Desktop Gateway that creates a room once [created] completes.
final class _CreatingGateway {
  _CreatingGateway() {
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
      final id = frame['id'];
      if (id == null) return;
      void reply(Object? result) => incoming.add(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      );
      if (frame['method'] == 'groups.create') {
        created.future.then((room) => reply({'room': room}));
      } else {
        scheduleMicrotask(() => reply(<String, Object?>{}));
      }
    });
  }

  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final created = Completer<Map<String, Object?>>();

  late final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
    ),
    dio: Dio()..httpClientAdapter = _StatusAdapter(),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => channel,
    ),
  );

  Future<void> close() async {
    service.close();
    await incoming.close();
  }
}

/// A room controller that shows a fixed view and records what was asked.
class _FakeRoom extends HermesRoomController {
  _FakeRoom(super.roomId, this.seed);

  final HermesRoomView seed;
  final sent = <String>[];
  final continued = <String>[];
  final answers = <(String, String?)>[];
  final saved = <HermesRoomContext>[];
  var stops = 0;
  var disbanded = 0;
  var refreshes = 0;

  /// Holds sends until completed.
  Completer<void>? sendGate;

  /// How a send ends, after [sendGate]: null posts it.
  Future<void> Function(String text)? sendOutcome;

  /// Shows [view], as a read of the room does.
  void show(HermesRoomView view) => state = view;

  HermesRoomView get view => state;

  @override
  HermesRoomView build() => seed;

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Future<void> send(String text) async {
    sent.add(text);
    await sendGate?.future;
    await sendOutcome?.call(text);
  }

  @override
  Future<int> stop() async {
    stops++;
    return 1;
  }

  @override
  Future<void> continueDiscussion(String discussionEventId) async =>
      continued.add(discussionEventId);

  @override
  Future<void> answer(HermesRoomPendingAction action, {String? choice}) async =>
      answers.add((action.taskId, choice));

  @override
  Future<HermesRoomContext> saveContext(HermesRoomContext context) async {
    saved.add(context);
    return context;
  }

  @override
  Future<void> disband() async => disbanded++;
}

Widget _app({required List overrides, required Widget home}) =>
    ProviderScope(
      overrides: [...overrides],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  });
  tearDown(PreferencesStore.debugReset);

  group('sidebar section', () {
    var roomReads = 0;

    Future<void> pumpSection(
      WidgetTester tester, {
      HermesRoomCapabilities? capabilities,
      List<HermesRoom> rooms = const [],
      List<HermesBot> bots = _bots,
      HermesDesktopApiService? service,
    }) async {
      roomReads = 0;
      await tester.pumpWidget(
        _app(
          overrides: [
            hermesRoomCapabilitiesProvider.overrideWith(
              (ref) async => capabilities,
            ),
            hermesRoomsProvider.overrideWith((ref) async {
              roomReads++;
              return rooms;
            }),
            hermesBotsProvider.overrideWith((ref) async => bots),
            hermesApiServiceProvider.overrideWithValue(service),
          ],
          home: const Scaffold(
            body: CustomScrollView(slivers: [HermesRoomsSection()]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('lists rooms with their bots, and offers a new one', (
      tester,
    ) async {
      await pumpSection(
        tester,
        capabilities: const HermesRoomCapabilities(driver: true),
        rooms: [_room],
      );

      expect(find.text('Rooms'), findsOneWidget);
      expect(find.text('Daily standup'), findsOneWidget);
      expect(find.textContaining('2 bots'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('hermes-rooms-create')),
        findsOneWidget,
      );

      // Collapsing hides the rooms.
      await tester.tap(find.byKey(const ValueKey('hermes-rooms-header')));
      await tester.pump();
      expect(find.text('Daily standup'), findsNothing);
    });

    testWidgets('is absent without rooms to show or bots to seat', (
      tester,
    ) async {
      await pumpSection(tester, rooms: [_room]);
      expect(find.text('Rooms'), findsNothing);

      await pumpSection(
        tester,
        capabilities: const HermesRoomCapabilities(driver: true),
        bots: _bots.take(1).toList(),
      );
      expect(find.text('Rooms'), findsNothing);

      // Hermes seats only the profiles it names.
      await pumpSection(
        tester,
        capabilities: const HermesRoomCapabilities(
          driver: true,
          seatableProfiles: {'research'},
        ),
      );
      expect(find.text('Rooms'), findsNothing);
    });

    testWidgets('creating needs a name and two bots', (tester) async {
      await pumpSection(
        tester,
        capabilities: const HermesRoomCapabilities(driver: true),
      );

      await tester.tap(find.byKey(const ValueKey('hermes-rooms-create')));
      await tester.pumpAndSettle();
      ConduitButton submit() => tester.widget<ConduitButton>(
        find.byKey(const ValueKey('hermes-room-create-submit')),
      );

      expect(find.text('Research'), findsOneWidget);
      check(submit().onPressed).isNull();
      await tester.enterText(
        find.byKey(const ValueKey('hermes-room-create-name')),
        'Planning',
      );
      await tester.tap(
        find.byKey(const ValueKey('hermes-room-create-bot-research')),
      );
      await tester.pump();
      check(submit().onPressed).isNull();
      await tester.tap(
        find.byKey(const ValueKey('hermes-room-create-bot-scout')),
      );
      await tester.pump();
      check(submit().onPressed).isNotNull();
    });

    testWidgets('a picked bot the roster drops is not seated', (
      tester,
    ) async {
      final roster = [..._bots];
      await pumpSection(
        tester,
        capabilities: const HermesRoomCapabilities(driver: true),
        bots: roster,
      );

      await tester.tap(find.byKey(const ValueKey('hermes-rooms-create')));
      await tester.pumpAndSettle();
      ConduitButton submit() => tester.widget<ConduitButton>(
        find.byKey(const ValueKey('hermes-room-create-submit')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('hermes-room-create-name')),
        'Planning',
      );
      for (final bot in ['research', 'scout']) {
        await tester.tap(
          find.byKey(ValueKey('hermes-room-create-bot-$bot')),
        );
        await tester.pump();
      }
      check(submit().onPressed).isNotNull();

      // The roster refreshes without one of the picked bots.
      roster.removeWhere((bot) => bot.name == 'scout');
      ProviderScope.containerOf(
        tester.element(find.byType(HermesRoomsSection)),
      ).invalidate(hermesBotsProvider);
      await tester.pumpAndSettle();

      check(submit().onPressed).isNull();
    });

    testWidgets('a room created after the sheet closed still lists', (
      tester,
    ) async {
      final gateway = _CreatingGateway();
      await pumpSection(
        tester,
        capabilities: const HermesRoomCapabilities(driver: true),
        service: gateway.service,
      );
      await tester.tap(find.byKey(const ValueKey('hermes-rooms-create')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('hermes-room-create-name')),
        'Planning',
      );
      for (final bot in ['research', 'scout']) {
        await tester.tap(
          find.byKey(ValueKey('hermes-room-create-bot-$bot')),
        );
        await tester.pump();
      }
      await tester.tap(
        find.byKey(const ValueKey('hermes-room-create-submit')),
      );
      await tester.pump();
      final reads = roomReads;

      // Closed while Hermes creates the room.
      final name = find.byKey(const ValueKey('hermes-room-create-name'));
      Navigator.of(tester.element(name)).pop();
      await tester.pumpAndSettle();
      gateway.created.complete({
        'room_id': 'planning',
        'name': 'Planning',
        'members': [
          for (final bot in ['research', 'scout'])
            {'member_id': bot, 'profile': bot, 'handle': bot},
        ],
      });
      await tester.pumpAndSettle();

      check(roomReads).isGreaterThan(reads);
      await gateway.close();
    });

    testWidgets('says when a room was active in the app language', (
      tester,
    ) async {
      final now = DateTime(2026, 1, 7, 12);
      final monday = DateTime(2026, 1, 5, 9);
      String? label;
      await tester.pumpWidget(
        Localizations(
          locale: const Locale('de'),
          delegates: AppLocalizations.localizationsDelegates,
          child: Builder(
            builder: (context) {
              label = hermesRoomActivityLabel(
                monday,
                context: context,
                now: now,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pump();

      check(label).equals('Mo');
    });
  });

  group('room page', () {
    late _FakeRoom room;

    Future<void> pumpRoom(
      WidgetTester tester,
      HermesRoomView view, {
      ValueListenable<bool>? inView,
    }) async {
      const page = HermesRoomPage(roomId: 'standup');
      await tester.pumpWidget(
        _app(
          overrides: [
            hermesRoomProvider.overrideWith2(
              (roomId) => room = _FakeRoom(roomId, view),
            ),
            hermesBotsProvider.overrideWith((ref) async => _bots),
            hermesApiServiceProvider.overrideWithValue(null),
          ],
          // The router keeps a page of a hidden destination mounted, with
          // its tickers muted.
          home: inView == null
              ? page
              : ValueListenableBuilder<bool>(
                  valueListenable: inView,
                  builder: (_, enabled, child) =>
                      TickerMode(enabled: enabled, child: child!),
                  child: page,
                ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    HermesRoomView liveView() {
      final now = DateTime.now();
      return HermesRoomView(
        loaded: true,
        snapshot: HermesRoomState(
          room: _room,
          context: const HermesRoomContext(),
          driver: HermesRoomDriverStatus(
            working: true,
            maxContinues: 5,
            memberActivity: [
              HermesRoomMemberActivity(
                memberId: 'research',
                status: 'running',
                startedAt: now.subtract(const Duration(seconds: 7)),
                tool: 'terminal',
              ),
            ],
            pendingActions: [
              HermesRoomPendingAction.fromJson({
                'kind': 'approval',
                'member_id': 'scout',
                'task_id': 'task-9',
                'execution_generation': 1,
                'request_id': 'req-9',
                'approval': {
                  'command': 'ls -la',
                  'choices': ['once', 'deny'],
                },
              })!,
            ],
          ),
        ),
        events: [
          _event(
            1,
            'message.user',
            {'text': 'Plan the week', 'thread_id': 'm1'},
            actor: {'kind': 'user', 'id': 'desktop'},
            id: 'm1',
          ),
          _event(
            2,
            'message.member',
            {
              'text': 'Here is a plan',
              'thread_id': 'm1',
              'discussion_event_id': 'm1',
            },
            actor: {'kind': 'member', 'id': 'research'},
          ),
          _event(3, 'turn.failed', {
            'member_id': 'scout',
            'discussion_event_id': 'm1',
            'thread_id': 'm1',
            'error': 'Model timed out',
          }),
          _event(4, 'room.activity', {
            'status': 'bounded',
            'reason_code': 'max_rounds',
            'thread_id': 'm1',
            'discussion_event_id': 'm1',
          }),
        ],
      );
    }

    testWidgets('reads like a chat with live status and decisions', (
      tester,
    ) async {
      await pumpRoom(tester, liveView());

      expect(
        find.byKey(const ValueKey('hermes-room-title-name')),
        findsOneWidget,
      );
      final status = tester.widget<Text>(
        find.byKey(const ValueKey('hermes-room-status')),
      );
      // A pending approval outranks who is working.
      check(status.data).equals('Needs your answer');
      expect(find.text('Plan the week'), findsOneWidget);
      expect(find.text('Research'), findsWidgets);
      expect(find.textContaining('Model timed out'), findsOneWidget);
      expect(find.text('Paused after 1 message'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hermes-room-continue')));
      await tester.pump();
      check(room.continued).deepEquals(['m1']);

      await tester.tap(find.text('Allow once'));
      await tester.pump();
      check(room.answers).deepEquals([('task-9', 'once')]);

      await unmount(tester);
    });

    testWidgets('a paused discussion with nothing running ends from its '
        'card', (tester) async {
      final live = liveView();
      await pumpRoom(
        tester,
        HermesRoomView(
          loaded: true,
          snapshot: HermesRoomState(
            room: _room,
            context: const HermesRoomContext(),
            driver: const HermesRoomDriverStatus(
              working: false,
              maxContinues: 5,
            ),
          ),
          events: live.events,
        ),
      );

      final stop = find.descendant(
        of: find.byKey(const ValueKey('hermes-room-pause-4')),
        matching: find.text('Stop'),
      );
      check(
        tester
            .widget<ConduitButton>(
              find.ancestor(of: stop, matching: find.byType(ConduitButton)),
            )
            .onPressed,
      ).isNotNull();
      await tester.tap(stop);
      await tester.pump();
      check(room.stops).equals(1);

      await unmount(tester);
    });

    testWidgets('shows who works by the title', (tester) async {
      final live = liveView();
      await pumpRoom(
        tester,
        HermesRoomView(
          loaded: true,
          events: live.events,
          snapshot: HermesRoomState(
            room: _room,
            driver: HermesRoomDriverStatus(
              working: true,
              memberActivity: live.driver!.memberActivity,
            ),
          ),
        ),
      );

      final status = tester.widget<Text>(
        find.byKey(const ValueKey('hermes-room-status')),
      );
      check(status.data).isNotNull().startsWith('Research · terminal · ');
      // Stop sits in the composer while nothing is typed.
      await tester.tap(find.byKey(const ValueKey('hermes-room-stop')));
      await tester.pump();
      check(room.stops).equals(1);

      await unmount(tester);
    });

    testWidgets('completes @mentions and sends', (tester) async {
      await pumpRoom(tester, liveView());

      final field = find.byKey(const ValueKey('hermes-room-composer'));
      await tester.enterText(field, 'Hi @sc');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('hermes-room-mention-scout')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('hermes-room-mention-scout')));
      await tester.pump();
      expect(find.text('Hi @scout '), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hermes-room-send')));
      await tester.pump();
      check(room.sent).deepEquals(['Hi @scout']);
      expect(find.text('Hi @scout '), findsNothing);

      await unmount(tester);
    });

    testWidgets('keeps words typed while a message sends', (tester) async {
      await pumpRoom(tester, liveView());
      final gate = room.sendGate = Completer<void>();

      final field = find.byKey(const ValueKey('hermes-room-composer'));
      await tester.enterText(field, 'First');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hermes-room-send')));
      await tester.pump();
      await tester.enterText(field, 'Second');
      gate.complete();
      await tester.pump();

      check(room.sent).deepEquals(['First']);
      expect(find.text('Second'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a message the log settles leaves the field', (tester) async {
      await pumpRoom(tester, liveView());
      // Hermes' answer is lost: the words stay, marked unclear.
      room.sendOutcome = (text) async {
        room.show(room.view.copyWith(sending: false, unsentText: text));
        throw StateError('answer lost');
      };
      final field = find.byKey(const ValueKey('hermes-room-composer'));
      await tester.enterText(field, 'Ship it');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hermes-room-send')));
      await tester.pump();
      expect(find.text('Ship it'), findsOneWidget);

      // A later read finds the message in the log.
      room.show(room.view.copyWith(unsentText: null));
      await tester.pump();

      expect(find.text('Ship it'), findsNothing);
      await unmount(tester);
    });

    testWidgets('refused words stay for editing', (tester) async {
      await pumpRoom(tester, liveView());
      final refusal = Completer<void>();
      room.sendOutcome = (text) async {
        room.show(room.view.copyWith(sending: true, unsentText: text));
        await refusal.future;
        // Hermes refused before posting anything: the send settles it.
        room.show(room.view.copyWith(sending: false, unsentText: null));
        throw StateError('refused');
      };
      final field = find.byKey(const ValueKey('hermes-room-composer'));
      await tester.enterText(field, 'Ship it');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('hermes-room-send')));
      await tester.pump();
      refusal.complete();
      await tester.pump();
      await tester.pump();

      expect(find.text('Ship it'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('stops reading the room while it is out of sight', (
      tester,
    ) async {
      final inView = ValueNotifier(true);
      addTearDown(inView.dispose);
      await pumpRoom(tester, liveView(), inView: inView);
      await tester.pump(kHermesRoomPollInterval);
      final seen = room.refreshes;
      check(seen).isGreaterThan(0);

      inView.value = false;
      await tester.pump();
      final hidden = room.refreshes;
      await tester.pump(kHermesRoomPollInterval * 5);
      check(room.refreshes).equals(hidden);

      inView.value = true;
      await tester.pump();
      await tester.pump();
      check(room.refreshes).isGreaterThan(hidden);

      await unmount(tester);
    });

    HermesRoomView settingsView() => HermesRoomView(
      loaded: true,
      snapshot: HermesRoomState(
        room: _room,
        context: const HermesRoomContext(
          purpose: 'Plan the week',
          routing: HermesRoomRouting.everyone,
        ),
        driver: const HermesRoomDriverStatus(
          routingModes: {
            HermesRoomRouting.everyone,
            HermesRoomRouting.lead,
            HermesRoomRouting.auto,
          },
        ),
      ),
    );

    testWidgets('room info saves purpose, notes and a lead', (tester) async {
      await pumpRoom(tester, settingsView());

      await tester.tap(find.byKey(const ValueKey('hermes-room-title')));
      await tester.pumpAndSettle();
      expect(find.text('Plan the week'), findsWidgets);
      ConduitButton save() => tester.widget<ConduitButton>(
        find.byKey(const ValueKey('hermes-room-save')),
      );
      check(save().onPressed).isNull();

      await tester.enterText(
        find.byKey(const ValueKey('hermes-room-notes')),
        'Keep it short',
      );
      await tester.tap(find.text('Lead bot'));
      await tester.pump();
      await _scrollTo(tester, 'hermes-room-member-scout');
      await tester.tap(find.byKey(const ValueKey('hermes-room-member-scout')));
      await tester.pump();
      await _scrollTo(tester, 'hermes-room-save');
      await tester.tap(find.byKey(const ValueKey('hermes-room-save')));
      await tester.pump();

      final saved = room.saved.single;
      check(saved.purpose).equals('Plan the week');
      check(saved.notes).equals('Keep it short');
      check(saved.routing).equals(HermesRoomRouting.lead);
      check(saved.leadMemberId).equals('scout');

      await unmount(tester);
    });

    testWidgets('disbanding asks first', (tester) async {
      await pumpRoom(tester, settingsView());

      await tester.tap(find.byKey(const ValueKey('hermes-room-title')));
      await tester.pumpAndSettle();
      await _scrollTo(tester, 'hermes-room-disband');
      await tester.tap(find.byKey(const ValueKey('hermes-room-disband')));
      await tester.pumpAndSettle();
      check(room.disbanded).equals(0);
      expect(find.text('Disband “Daily standup”?'), findsOneWidget);

      await tester.tap(find.text('Disband room').last);
      await tester.pumpAndSettle();
      check(room.disbanded).equals(1);

      await unmount(tester);
    });

    testWidgets('two bots of one name each show who wrote', (tester) async {
      Map<String, Object?> seat(String id) => {
        'member_id': id,
        'profile': id,
        'handle': id,
        'display_name': 'Helper',
      };
      final twins = HermesRoom.fromJson({
        'room_id': 'twins',
        'name': 'Twins',
        'members': [seat('a'), seat('b')],
      })!;
      HermesRoomEvent reply(int seq, String member) => _event(
        seq,
        'message.member',
        {
          'text': 'Reply $seq',
          'thread_id': 'm1',
          'discussion_event_id': 'm1',
          'member_id': member,
        },
        actor: {'kind': 'member', 'id': member},
      );
      final items = projectHermesRoomTimeline([
        reply(1, 'a'),
        reply(2, 'b'),
        reply(3, 'b'),
      ], twins).whereType<HermesRoomMessageItem>().toList();

      await tester.pumpWidget(
        _app(
          overrides: const [],
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < items.length; i++)
                  HermesRoomTimelineRow(
                    item: items[i],
                    roomId: 'twins',
                    previous: i == 0 ? null : items[i - 1],
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // Each bot's first reply names it; the second bot's next one does not.
      expect(find.text('Helper'), findsNWidgets(2));
    });

    testWidgets('says when the room is gone', (tester) async {
      await pumpRoom(
        tester,
        const HermesRoomView(loaded: true, gone: true),
      );

      expect(find.text('This room is no longer available.'), findsOneWidget);

      await unmount(tester);
    });
  });
}

/// Scrolls the room info sheet until the lazily built [key] exists and is on
/// screen.
Future<void> _scrollTo(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey<String>(key)),
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.pump();
}
