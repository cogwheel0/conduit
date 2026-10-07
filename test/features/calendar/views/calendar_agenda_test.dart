import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/features/calendar/models/calendar_models.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'calendar_harness.dart';

Finder item(String key) => find.byKey(Key('calendar-item-$key'));

void main() {
  group('the agenda', () {
    testWidgets('groups events by their day in the device zone', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) {
          wire.events = [
            // 2026-10-06 17:09 to 18:09 at UTC-4.
            eventJson('ev-mine', 'cal-mine', title: 'Planning'),
            // 2026-10-12 00:00 to 2026-10-14 23:59 at UTC-4.
            eventJson(
              'ev-trip',
              'cal-ro',
              title: 'Offsite',
              allDay: true,
              startAt: 1791777600000000000,
              endAt: 1792036740000000000,
            ),
          ];
        },
      );

      expect(find.byKey(const Key('calendar-range')), findsOneWidget);
      expect(find.text('Oct 6 – Oct 19'), findsOneWidget);
      expect(find.text('Tue, Oct 6'), findsOneWidget);
      expect(find.text('5:09 PM – 6:09 PM'), findsOneWidget);
      // A span of days is listed on each of them.
      for (final day in ['Mon, Oct 12', 'Tue, Oct 13', 'Wed, Oct 14']) {
        expect(find.text(day), findsOneWidget);
      }
      expect(find.text('Offsite'), findsNWidgets(3));
      expect(find.text('All day'), findsNWidgets(3));
      expect(find.byKey(const Key('calendar-timezone-note')), findsOneWidget);
    });

    testWidgets('lists every occurrence of a recurring event', (tester) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) {
          wire.agendaOverride = [
            for (final day in [0, 7])
              eventJson(
                'series-1',
                'cal-mine',
                title: 'Weekly sync',
                rrule: 'FREQ=WEEKLY',
                instanceId: 'series-1_$day',
                startAt: 1791320967123456789 + day * 86400000000000,
              ),
          ];
        },
      );

      expect(find.text('Weekly sync'), findsNWidgets(2));
      expect(item('series-1|series-1_0'), findsOneWidget);
      expect(item('series-1|series-1_7'), findsOneWidget);
      expect(find.text('Tue, Oct 13'), findsOneWidget);
    });

    testWidgets('asks for the range and calendars the user chose', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      expect(session.wire.agendaRequests.last.uri.queryParameters, {
        'start': '2026-10-06T00:00:00-04:00',
        'end': '2026-10-20T00:00:00-04:00',
      });

      await tester.tap(find.byKey(const Key('calendar-later')));
      await tester.pumpAndSettle();
      expect(session.wire.agendaRequests.last.uri.queryParameters, {
        'start': '2026-10-20T00:00:00-04:00',
        'end': '2026-11-03T00:00:00-04:00',
      });
      expect(find.text('Oct 20 – Nov 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('calendar-today')));
      await tester.pumpAndSettle();
      expect(find.text('Oct 6 – Oct 19'), findsOneWidget);

      await tester.tap(find.byKey(const Key('calendar-filter-cal-ro')));
      await tester.pumpAndSettle();
      expect(
        session.wire.agendaRequests.last.uri.queryParameters['calendar_ids'],
        'cal-ro',
      );

      await tester.tap(find.byKey(const Key('calendar-filter-all')));
      await tester.pumpAndSettle();
      expect(
        session.wire.agendaRequests.last.uri.queryParameters.containsKey(
          'calendar_ids',
        ),
        isFalse,
      );
    });

    testWidgets('says so when there is nothing in the period', (tester) async {
      await pumpCalendar(tester, configureWire: (wire) => wire.events = []);

      expect(find.byKey(const Key('calendar-empty')), findsOneWidget);
    });
  });

  group('who may open it', () {
    testWidgets('anyone the server allows, with Advanced off', (tester) async {
      final session = await pumpCalendar(tester);

      expect(
        session.container.read(appSettingsProvider).advancedFeaturesEnabled,
        isFalse,
      );
      expect(find.byKey(const Key('calendar-range')), findsOneWidget);
    });

    testWidgets('a server or account without the calendar sees why', (
      tester,
    ) async {
      final off = await pumpCalendar(tester, serverEnabled: false);
      expect(find.byKey(const Key('calendar-unavailable')), findsOneWidget);
      expect(off.wire.requests, isEmpty);
    });

    testWidgets('an account without the permission sees why', (tester) async {
      final session = await pumpCalendar(
        tester,
        permissions: const {
          'features': {'calendar': false},
        },
      );

      expect(find.byKey(const Key('calendar-unavailable')), findsOneWidget);
      expect(session.wire.requests, isEmpty);
    });
  });

  group('scheduled tasks', () {
    void withScheduled(CalendarWire wire) {
      wire.virtualCalendar = true;
      wire.events = [];
      wire.scheduled = [
        scheduledEntryJson('auto_a1'),
        scheduledEntryJson(
          'run_chan',
          runId: 'r1',
          chatId: 'channel:chan-1',
          status: 'success',
          startAt: 1791300000000000000,
        ),
        scheduledEntryJson(
          'run_chat',
          runId: 'r2',
          chatId: 'chat-9',
          status: 'success',
          startAt: 1791290000000000000,
        ),
        scheduledEntryJson(
          'run_bad',
          runId: 'r3',
          status: 'error',
          startAt: 1791280000000000000,
        ),
      ];
    }

    testWidgets('are listed apart from events, with their state', (
      tester,
    ) async {
      await pumpCalendar(tester, configureWire: withScheduled);

      expect(find.text('Scheduled task'), findsNothing);
      expect(find.textContaining('Scheduled task'), findsOneWidget);
      expect(find.textContaining('Task run finished'), findsNWidgets(2));
      expect(find.textContaining('Task run failed'), findsOneWidget);
    });

    testWidgets('a future entry opens its task and nothing is mutated', (
      tester,
    ) async {
      final session = await pumpCalendar(tester, configureWire: withScheduled);

      await tester.tap(item('auto_a1|'));
      await tester.pumpAndSettle();

      expect(find.byKey(calendarScheduledTaskKey('a1')), findsOneWidget);
      expect(session.wire.writes, isEmpty);
      // Neither the entry nor its id ever reached an event route.
      expect(
        session.wire.requests.where(
          (r) => r.uri.path.contains('auto_') || r.uri.path.contains('run_'),
        ),
        isEmpty,
      );
    });

    // The shell is already mounted under the calendar whatever the user came
    // from. A flat test router would not notice a page pushed into it twice.
    for (final (underneath, shellLocation) in [
      ('chat', Routes.chat),
      ('another channel', '/channel/other'),
    ]) {
      testWidgets('a channel result opens the channel over $underneath', (
        tester,
      ) async {
        final session = await pumpCalendar(
          tester,
          configureWire: withScheduled,
          shellLocation: shellLocation,
        );

        await tester.tap(item('run_chan|'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(calendarShellKey), findsOneWidget);
        expect(find.byKey(calendarChannelKey('chan-1')), findsOneWidget);
        expect(session.wire.writes, isEmpty);
      });
    }

    testWidgets('a chat result opens that chat in the shell', (tester) async {
      await pumpCalendar(tester, configureWire: withScheduled);

      await tester.tap(item('run_chat|'));
      await tester.pumpAndSettle();

      expect(FakeSelection.selected.single.id, 'chat-9');
      expect(find.byKey(calendarShellKey), findsOneWidget);
      expect(find.byKey(calendarChatKey), findsOneWidget);
    });

    testWidgets('a run with no result opens its task', (tester) async {
      await pumpCalendar(tester, configureWire: withScheduled);

      await tester.tap(item('run_bad|'));
      await tester.pumpAndSettle();

      expect(find.byKey(calendarScheduledTaskKey('a1')), findsOneWidget);
    });

    testWidgets('are not offered to an account without scheduled tasks', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: withScheduled,
        permissions: const {
          'features': {'calendar': true, 'automations': false},
        },
      );

      expect(item('auto_a1|'), findsNothing);
      expect(find.textContaining('Task run'), findsNothing);
    });
  });

  group('an invitation', () {
    // The agenda lists an event the account only attends even when it has no
    // grant on its calendar; the detail route would refuse it.
    void withInvitation(CalendarWire wire) {
      wire.events = [
        eventJson(
          'ev-invite',
          'cal-hidden',
          title: 'Board meeting',
          owner: 'user-9',
          attendees: [attendeeJson('ev-invite', 'user-1')],
        ),
      ];
    }

    testWidgets('is answered from the agenda copy without a detail read', (
      tester,
    ) async {
      final session = await pumpCalendar(tester, configureWire: withInvitation);
      expect(find.text('No response yet'), findsOneWidget);

      await tester.tap(item('ev-invite|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-title')), findsOneWidget);
      // It cannot be edited or deleted, only answered.
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      expect(find.byKey(const Key('calendar-event-delete')), findsNothing);
      expect(find.byKey(const Key('calendar-event-read-only')), findsOneWidget);
      expect(
        session.wire.requests.where(
          (r) => r.uri.path == '/api/v1/calendars/events/ev-invite',
        ),
        isEmpty,
      );

      await tester.tap(find.byKey(const Key('calendar-rsvp-tentative')));
      await tester.pumpAndSettle();

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/events/ev-invite/rsvp');
      expect(write.data, {'status': 'tentative'});
      expect(
        session.wire.stored('ev-invite')!['attendees'][0]['status'],
        'tentative',
      );
      expect(find.text('Maybe'), findsWidgets);
    });

    testWidgets('a refused RSVP says so and changes nothing', (tester) async {
      final session = await pumpCalendar(tester, configureWire: withInvitation);
      session.wire.rejectWrites = (status: 404, detail: 'Not an attendee');

      await tester.tap(item('ev-invite|'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-rsvp-accepted')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-error')), findsOneWidget);
      expect(
        session.wire.stored('ev-invite')!['attendees'][0]['status'],
        'pending',
      );
    });

    testWidgets('an invited person with read-only access can still answer', (
      tester,
    ) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) => wire.events = [
          eventJson(
            'ev-ro',
            'cal-ro',
            title: 'Open house',
            owner: 'user-9',
            attendees: [attendeeJson('ev-ro', 'user-1')],
          ),
        ],
      );

      await tester.tap(item('ev-ro|'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-rsvp-declined')));
      await tester.pumpAndSettle();

      expect(session.wire.writes.single.uri.path, endsWith('/ev-ro/rsvp'));
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
    });
  });

  group('an event the account may change', () {
    testWidgets('can be edited and deleted', (tester) async {
      await pumpCalendar(tester);

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-edit')), findsOneWidget);
      expect(find.byKey(const Key('calendar-event-delete')), findsOneWidget);
    });

    testWidgets('an event in a read-only calendar can be neither', (
      tester,
    ) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) =>
            wire.events = [eventJson('ev-ro', 'cal-ro', title: 'Holiday')],
      );

      await tester.tap(item('ev-ro|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      expect(find.byKey(const Key('calendar-event-delete')), findsNothing);
      expect(find.byKey(const Key('calendar-event-read-only')), findsOneWidget);
    });

    testWidgets('a refused detail read keeps the agenda copy, turns editing '
        'off and refreshes the agenda', (tester) async {
      final session = await pumpCalendar(tester);
      final before = session.wire.agendaRequests.length;
      session.wire.denyDetail = true;

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-title')), findsOneWidget);
      expect(find.text('Planning'), findsWidgets);
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      expect(find.byKey(const Key('calendar-event-delete')), findsNothing);
      expect(session.wire.agendaRequests.length, greaterThan(before));
    });

    testWidgets('an event deleted elsewhere says so and refreshes', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);
      session.wire.events.clear();
      final before = session.wire.agendaRequests.length;

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('calendar-event-gone')), findsOneWidget);
      expect(find.byKey(const Key('calendar-event-edit')), findsNothing);
      expect(session.wire.agendaRequests.length, greaterThan(before));
    });

    testWidgets('deleting asks first and then removes the event', (
      tester,
    ) async {
      final session = await pumpCalendar(tester);

      await tester.tap(item('ev-mine|'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('calendar-event-delete')));
      await tester.pumpAndSettle();
      // Declining deletes nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(session.wire.writes, isEmpty);

      await tester.tap(find.byKey(const Key('calendar-event-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ConduitTextButton, 'Delete'));
      await tester.pumpAndSettle();

      final write = session.wire.writes.single;
      expect(write.method, 'DELETE');
      expect(write.uri.path, '/api/v1/calendars/events/ev-mine/delete');
      expect(session.wire.events, isEmpty);
      expect(item('ev-mine|'), findsNothing);
    });

    testWidgets('a series is edited and deleted as a whole', (tester) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) {
          wire.events = [
            eventJson(
              'series-1',
              'cal-mine',
              title: 'Weekly sync',
              rrule: 'FREQ=WEEKLY',
            ),
          ];
          wire.agendaOverride = [
            eventJson(
              'series-1',
              'cal-mine',
              title: 'Weekly sync',
              rrule: 'FREQ=WEEKLY',
              instanceId: 'series-1_1',
            ),
          ];
        },
      );

      await tester.tap(item('series-1|series-1_1'));
      await tester.pumpAndSettle();

      expect(find.text('Edit series'), findsOneWidget);
      expect(find.text('Delete series'), findsOneWidget);
      expect(find.byKey(const Key('calendar-event-repeat')), findsOneWidget);

      await tester.tap(find.byKey(const Key('calendar-event-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ConduitTextButton, 'Delete series'));
      await tester.pumpAndSettle();

      expect(
        session.wire.writes.single.uri.path,
        '/api/v1/calendars/events/series-1/delete',
      );
    });
  });

  group('calendars', () {
    testWidgets('only the account\'s own calendar can be made its default', (
      tester,
    ) async {
      final session = await pumpCalendar(
        tester,
        configureWire: (wire) => wire.calendars.add(
          calendarJson('cal-work', 'user-1', name: 'Work'),
        ),
      );

      await tester.tap(find.byKey(const Key('calendar-manage-calendars')));
      await tester.pumpAndSettle();

      // The other owner's default and a shared calendar get no button, and the
      // account's current default has nothing to offer.
      expect(
        find.byKey(const Key('calendar-make-default-cal-ro')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('calendar-make-default-cal-rw')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('calendar-make-default-cal-mine')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('calendar-make-default-cal-work')));
      await tester.pumpAndSettle();

      final write = session.wire.writes.single;
      expect(write.uri.path, '/api/v1/calendars/cal-work/default');
      // Another owner's default stays theirs.
      expect(
        session.wire.calendars.firstWhere(
          (c) => c['id'] == 'cal-ro',
        )['is_default'],
        isTrue,
      );
    });

    testWidgets('the scheduled-tasks calendar cannot be chosen as a default '
        'or listed for events', (tester) async {
      await pumpCalendar(
        tester,
        configureWire: (wire) => wire.virtualCalendar = true,
      );

      await tester.tap(find.byKey(const Key('calendar-manage-calendars')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('calendar-row-$scheduledTasksCalendarId')),
        findsNothing,
      );
    });
  });
}
