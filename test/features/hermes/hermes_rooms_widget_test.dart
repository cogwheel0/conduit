import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/views/hermes_room_page.dart';
import 'package:conduit/features/hermes/widgets/hermes_rooms_section.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_room.dart';
import 'package:conduit_core/features/hermes/models/hermes_room_log.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_room_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  @override
  HermesRoomView build() => seed;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> send(String text) async => sent.add(text);

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
  Future<void> saveContext(HermesRoomContext context) async =>
      saved.add(context);

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
    Future<void> pumpSection(
      WidgetTester tester, {
      HermesRoomCapabilities? capabilities,
      List<HermesRoom> rooms = const [],
      List<HermesBot> bots = _bots,
    }) async {
      await tester.pumpWidget(
        _app(
          overrides: [
            hermesRoomCapabilitiesProvider.overrideWith(
              (ref) async => capabilities,
            ),
            hermesRoomsProvider.overrideWith((ref) async => rooms),
            hermesBotsProvider.overrideWith((ref) async => bots),
            hermesApiServiceProvider.overrideWithValue(null),
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
  });

  group('room page', () {
    late _FakeRoom room;

    Future<void> pumpRoom(WidgetTester tester, HermesRoomView view) async {
      await tester.pumpWidget(
        _app(
          overrides: [
            hermesRoomProvider.overrideWith2(
              (roomId) => room = _FakeRoom(roomId, view),
            ),
            hermesBotsProvider.overrideWith((ref) async => _bots),
            hermesApiServiceProvider.overrideWithValue(null),
          ],
          home: const HermesRoomPage(roomId: 'standup'),
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
